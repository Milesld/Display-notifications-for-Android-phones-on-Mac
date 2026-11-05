'use strict';

const assert = require('assert');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const tls = require('tls');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'notifybridge-relay-test-'));
const cert = path.join(tmp, 'cert.pem');
const key = path.join(tmp, 'key.pem');
const dataDir = path.join(tmp, 'data');
const port = 18443;
const channel = '0123456789abcdef0123456789abcdef';
const token = 'test-token-0123456789abcdef';

execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1',
    '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
], { stdio: 'ignore' });

let child = null;

function startServer() {
    child = spawn(process.execPath, [path.join(__dirname, '..', 'relay.js')], {
        env: {
            ...process.env,
            PORT: String(port),
            TLS_CERT: cert,
            TLS_KEY: key,
            DATA_DIR: dataDir,
        },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', (chunk) => process.stdout.write(`[relay] ${chunk}`));
    child.stderr.on('data', (chunk) => process.stderr.write(`[relay:err] ${chunk}`));
    return child;
}

function stopServer() {
    return new Promise((resolve) => {
        if (!child || child.exitCode !== null) return resolve();
        child.once('exit', resolve);
        child.kill('SIGTERM');
        setTimeout(() => {
            if (child.exitCode === null) child.kill('SIGKILL');
        }, 3000).unref();
    });
}

class Client {
    constructor(socket) {
        this.socket = socket;
        this.buffer = Buffer.alloc(0);
        this.messages = [];
        this.waiters = [];
        socket.on('data', (chunk) => this.onData(chunk));
        socket.on('error', () => {});
    }

    onData(chunk) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        while (this.buffer.length >= 4) {
            const length = this.buffer.readUInt32BE(0);
            if (this.buffer.length < 4 + length) return;
            const payload = this.buffer.subarray(4, 4 + length);
            this.buffer = this.buffer.subarray(4 + length);
            const value = JSON.parse(payload.toString('utf8'));
            const waiter = this.waiters.find((w) => w.type === value.type);
            if (waiter) {
                this.waiters.splice(this.waiters.indexOf(waiter), 1);
                clearTimeout(waiter.timer);
                waiter.resolve(value);
            } else {
                this.messages.push(value);
            }
        }
    }

    next(type, timeout = 3000) {
        const index = this.messages.findIndex((m) => m.type === type);
        if (index >= 0) return Promise.resolve(this.messages.splice(index, 1)[0]);
        return new Promise((resolve, reject) => {
            const waiter = { type, resolve };
            waiter.timer = setTimeout(() => {
                this.waiters.splice(this.waiters.indexOf(waiter), 1);
                reject(new Error(`Timed out waiting for ${type}`));
            }, timeout);
            this.waiters.push(waiter);
        });
    }

    send(value) {
        const payload = Buffer.from(JSON.stringify(value), 'utf8');
        const header = Buffer.alloc(4);
        header.writeUInt32BE(payload.length, 0);
        this.socket.write(Buffer.concat([header, payload]));
    }

    close() {
        return new Promise((resolve) => {
            this.socket.once('close', resolve);
            this.socket.end();
        });
    }
}

async function connect() {
    for (let attempt = 0; attempt < 60; attempt++) {
        try {
            const socket = await new Promise((resolve, reject) => {
                const s = tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false }, () => resolve(s));
                s.once('error', reject);
            });
            socket.removeAllListeners('error');
            return new Client(socket);
        } catch (error) {
            await new Promise((resolve) => setTimeout(resolve, 100));
        }
    }
    throw new Error('relay did not start');
}

async function register(client, role) {
    client.send({ v: 1, type: 'register', role, channel, token, name: role });
    const reply = await client.next('registered');
    assert.strictEqual(reply.role, role);
    return reply;
}

async function main() {
    startServer();
    let phone = await connect();
    await register(phone, 'phone');
    let mac = await connect();
    const macRegistration = await register(mac, 'mac');
    assert.strictEqual(macRegistration.peer, true);

    phone.send({ v: 1, type: 'deliver', id: 'm1', payload: 'cipher-1' });
    await phone.next('stored');
    const delivered = await mac.next('message');
    assert.strictEqual(delivered.id, 'm1');
    assert.strictEqual(delivered.payload, 'cipher-1');
    mac.send({ v: 1, type: 'ack', id: 'm1' });
    await phone.next('delivered');

    // Offline queue.
    await mac.close();
    phone.send({ v: 1, type: 'deliver', id: 'm2', payload: 'cipher-2' });
    await phone.next('stored');
    mac = await connect();
    const macRegistration2 = await register(mac, 'mac');
    assert.strictEqual(macRegistration2.peer, true);
    const queued = await mac.next('message');
    assert.strictEqual(queued.id, 'm2');
    mac.send({ v: 1, type: 'ack', id: 'm2' });
    await phone.next('delivered');

    // Queue survives a relay restart.
    await mac.close();
    phone.send({ v: 1, type: 'deliver', id: 'm3', payload: 'cipher-3' });
    await phone.next('stored');
    await phone.close();
    await stopServer();
    startServer();
    mac = await connect();
    await register(mac, 'mac');
    const persisted = await mac.next('message');
    assert.strictEqual(persisted.id, 'm3');
    mac.send({ v: 1, type: 'ack', id: 'm3' });

    await mac.close();
    await stopServer();
    console.log('relay test passed');
}

main()
    .catch(async (error) => {
        console.error(error);
        await stopServer();
        process.exitCode = 1;
    })
    .finally(() => {
        try {
            fs.rmSync(tmp, { recursive: true, force: true });
        } catch (e) {
            // ignore
        }
    });
