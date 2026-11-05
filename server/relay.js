'use strict';

/**
 * NotifyBridge relay server.
 *
 * - TLS only, no third-party dependencies.
 * - Devices register with a channel id + auth token derived from a 32-byte
 *   secret. The server never sees that secret or the notification plaintext.
 * - Messages are routed to the peer and queued while the Mac is offline.
 * - The queue is persisted under DATA_DIR so a server restart does not lose
 *   undelivered notifications.
 *
 * Environment:
 *   PORT=8443
 *   TLS_CERT=/path/relay-cert.pem
 *   TLS_KEY=/path/relay-key.pem
 *   DATA_DIR=/path/data
 *   MAX_QUEUE=500
 *   QUEUE_TTL_MS=604800000
 */

const fs = require('fs');
const path = require('path');
const tls = require('tls');

const PORT = Number.parseInt(process.env.PORT || '8443', 10);
const CERT = process.env.TLS_CERT || path.join(__dirname, 'certs', 'relay-cert.pem');
const KEY = process.env.TLS_KEY || path.join(__dirname, 'certs', 'relay-key.pem');
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const MAX_QUEUE = Number.parseInt(process.env.MAX_QUEUE || '500', 10);
const QUEUE_TTL_MS = Number.parseInt(process.env.QUEUE_TTL_MS || String(7 * 24 * 60 * 60 * 1000), 10);
const MAX_PAYLOAD_BYTES = 512 * 1024;
const MAX_FRAME_BYTES = 1024 * 1024;

const channels = new Map();
const saveTimers = new Map();

function log(...args) {
    console.log(new Date().toISOString(), ...args);
}

function fail(message) {
    console.error(message);
    process.exit(1);
}

if (!fs.existsSync(CERT) || !fs.existsSync(KEY)) {
    fail(`TLS certificate/key not found.\n  cert: ${CERT}\n  key:  ${KEY}\nRun scripts/gen-relay-cert.sh or set TLS_CERT/TLS_KEY.`);
}

fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });

function channelFile(channel) {
    return path.join(DATA_DIR, `${channel}.json`);
}

function loadChannel(channel) {
    const file = channelFile(channel);
    if (!fs.existsSync(file)) return null;
    try {
        const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (!raw || typeof raw !== 'object') return null;
        const queue = Array.isArray(raw.queue) ? raw.queue.filter(isValidStoredMessage) : [];
        return {
            token: typeof raw.token === 'string' ? raw.token : '',
            queue,
            seen: new Map(queue.map((entry) => [entry.id, { ts: entry.ts, acked: false }])),
        };
    } catch (error) {
        log('Ignoring unreadable queue file', file, error.message);
        return null;
    }
}

function isValidStoredMessage(entry) {
    return entry
        && typeof entry.id === 'string'
        && entry.id.length > 0
        && entry.id.length <= 100
        && typeof entry.payload === 'string'
        && entry.payload.length <= MAX_PAYLOAD_BYTES
        && typeof entry.ts === 'number';
}

function saveChannel(channel, immediate = false) {
    const state = channels.get(channel);
    if (!state) return;
    const write = () => {
        saveTimers.delete(channel);
        const file = channelFile(channel);
        const temp = `${file}.tmp`;
        const data = JSON.stringify({ token: state.token, queue: state.queue });
        try {
            fs.writeFileSync(temp, data, { mode: 0o600 });
            fs.renameSync(temp, file);
        } catch (error) {
            log('Unable to persist queue', channel, error.message);
        }
    };
    if (immediate) {
        if (saveTimers.has(channel)) {
            clearTimeout(saveTimers.get(channel));
        }
        write();
        return;
    }
    if (saveTimers.has(channel)) return;
    saveTimers.set(channel, setTimeout(write, 200));
}

function getChannel(channel, token) {
    let state = channels.get(channel);
    if (!state) {
        const stored = loadChannel(channel);
        state = stored || { token, queue: [], seen: new Map() };
        if (!state.token) state.token = token;
        channels.set(channel, state);
        log('Channel opened', channel, 'queued=', state.queue.length);
    }
    if (state.token !== token) return null;
    return state;
}

function encodeFrame(value) {
    const payload = Buffer.from(JSON.stringify(value), 'utf8');
    const header = Buffer.alloc(4);
    header.writeUInt32BE(payload.length, 0);
    return Buffer.concat([header, payload]);
}

function send(conn, value) {
    if (!conn || conn.socket.destroyed) return false;
    try {
        conn.socket.write(encodeFrame(value));
        return true;
    } catch (error) {
        log('Send failed', error.message);
        conn.socket.destroy();
        return false;
    }
}

function errorAndClose(conn, code, message) {
    send(conn, { v: 1, type: 'error', code, message });
    conn.socket.end();
}

function handleFrame(conn, value) {
    conn.lastSeen = Date.now();
    if (!value || typeof value !== 'object') return;
    if (!conn.registered) {
        if (value.type !== 'register') {
            errorAndClose(conn, 'register_required', 'register first');
            return;
        }
        handleRegister(conn, value);
        return;
    }
    const state = channels.get(conn.channel);
    if (!state) {
        errorAndClose(conn, 'channel_missing', 'channel no longer exists');
        return;
    }
    switch (value.type) {
        case 'ping':
            send(conn, { v: 1, type: 'pong', time: Date.now() });
            break;
        case 'pong':
            break;
        case 'deliver':
            if (conn.role !== 'phone') return;
            handleDeliver(conn, state, value);
            break;
        case 'ack':
            if (conn.role !== 'mac') return;
            handleAck(conn, state, value);
            break;
        default:
            break;
    }
}

function handleRegister(conn, value) {
    const role = value.role;
    const channel = value.channel;
    const token = value.token;
    if (role !== 'phone' && role !== 'mac') {
        errorAndClose(conn, 'bad_role', 'role must be phone or mac');
        return;
    }
    if (typeof channel !== 'string' || !/^[0-9a-f]{32}$/.test(channel)) {
        errorAndClose(conn, 'bad_channel', 'invalid channel id');
        return;
    }
    if (typeof token !== 'string' || token.length < 20 || token.length > 100) {
        errorAndClose(conn, 'bad_token', 'invalid token');
        return;
    }
    const state = getChannel(channel, token);
    if (!state) {
        errorAndClose(conn, 'auth', 'token does not match channel');
        return;
    }
    const old = state[role];
    if (old && old !== conn) {
        try {
            old.socket.destroy();
        } catch (e) {
            // ignore
        }
    }
    state[role] = conn;
    conn.registered = true;
    conn.role = role;
    conn.channel = channel;
    const peer = role === 'phone' ? state.mac : state.phone;
    send(conn, {
        v: 1,
        type: 'registered',
        role,
        peer: Boolean(peer),
        queued: role === 'mac' ? state.queue.length : undefined,
    });
    log('Registered', role, channel.slice(0, 8), 'peer=', Boolean(peer), 'queued=', state.queue.length);
    if (peer) {
        send(peer, { v: 1, type: 'peer', peer: true });
    }
    if (role === 'mac') {
        flushQueue(state, conn);
    }
    saveChannel(channel);
}

function handleDeliver(conn, state, value) {
    const id = value.id;
    const payload = value.payload;
    if (typeof id !== 'string' || id.length === 0 || id.length > 100
        || typeof payload !== 'string' || Buffer.byteLength(payload, 'utf8') > MAX_PAYLOAD_BYTES) {
        send(conn, { v: 1, type: 'error', code: 'bad_message', message: 'invalid message' });
        return;
    }
    const previous = state.seen.get(id);
    if (previous) {
        send(conn, { v: 1, type: 'stored', id });
        if (previous.acked) {
            send(conn, { v: 1, type: 'delivered', id });
        } else if (state.mac) {
            send(state.mac, { v: 1, type: 'message', id, payload });
        }
        return;
    }

    const entry = { id, payload, ts: Date.now() };
    state.queue.push(entry);
    state.seen.set(id, { ts: entry.ts, acked: false });
    while (state.queue.length > MAX_QUEUE) {
        const dropped = state.queue.shift();
        if (dropped && !state.seen.has(dropped.id)) {
            state.seen.set(dropped.id, { ts: Date.now(), acked: false });
        }
    }
    send(conn, { v: 1, type: 'stored', id });
    if (state.mac) {
        send(state.mac, { v: 1, type: 'message', id, payload });
    }
    saveChannel(conn.channel);
}

function handleAck(conn, state, value) {
    const id = value.id;
    if (typeof id !== 'string') return;
    const index = state.queue.findIndex((entry) => entry.id === id);
    if (index >= 0) {
        state.queue.splice(index, 1);
        state.seen.set(id, { ts: Date.now(), acked: true });
        saveChannel(conn.channel);
    }
    if (state.phone) {
        send(state.phone, { v: 1, type: 'delivered', id });
    }
}

function flushQueue(state, conn) {
    for (const entry of state.queue) {
        send(conn, { v: 1, type: 'message', id: entry.id, payload: entry.payload });
    }
}

function onConnection(socket) {
    const conn = {
        socket,
        buffer: Buffer.alloc(0),
        registered: false,
        role: null,
        channel: null,
        lastSeen: Date.now(),
    };
    socket.setKeepAlive(true, 30_000);
    socket.on('data', (chunk) => {
        conn.lastSeen = Date.now();
        conn.buffer = Buffer.concat([conn.buffer, chunk]);
        while (conn.buffer.length >= 4) {
            const length = conn.buffer.readUInt32BE(0);
            if (length <= 0 || length > MAX_FRAME_BYTES) {
                errorAndClose(conn, 'bad_frame', 'invalid frame length');
                return;
            }
            if (conn.buffer.length < 4 + length) return;
            const payload = conn.buffer.subarray(4, 4 + length);
            conn.buffer = conn.buffer.subarray(4 + length);
            let value;
            try {
                value = JSON.parse(payload.toString('utf8'));
            } catch (error) {
                errorAndClose(conn, 'bad_json', 'invalid JSON');
                return;
            }
            try {
                handleFrame(conn, value);
            } catch (error) {
                log('Handler error', error.stack || error.message);
                errorAndClose(conn, 'internal', 'internal error');
                return;
            }
        }
    });
    socket.on('error', (error) => {
        log('Socket error', error.message);
    });
    socket.on('close', () => {
        if (conn.channel) {
            const state = channels.get(conn.channel);
            if (state && state[conn.role] === conn) {
                state[conn.role] = null;
                const other = conn.role === 'phone' ? state.mac : state.phone;
                if (other) send(other, { v: 1, type: 'peer', peer: false });
                log('Disconnected', conn.role, conn.channel.slice(0, 8));
            }
            saveChannel(conn.channel);
        }
    });
}

const server = tls.createServer({ cert: fs.readFileSync(CERT), key: fs.readFileSync(KEY) }, onConnection);
server.on('tlsClientError', (error) => {
    log('TLS client error', error.message);
});
server.listen(PORT, '0.0.0.0', () => {
    log(`NotifyBridge relay listening on 0.0.0.0:${PORT}`);
});

const heartbeat = setInterval(() => {
    const now = Date.now();
    for (const state of channels.values()) {
        for (const role of ['phone', 'mac']) {
            const conn = state[role];
            if (!conn) continue;
            if (now - conn.lastSeen > 90_000) {
                conn.socket.destroy();
                continue;
            }
            send(conn, { v: 1, type: 'ping', time: now });
        }
    }
}, 30_000);

const cleanup = setInterval(() => {
    const now = Date.now();
    for (const [channel, state] of channels) {
        let changed = false;
        for (const [id, seen] of state.seen) {
            if (now - seen.ts > QUEUE_TTL_MS) {
                state.seen.delete(id);
                changed = true;
            }
        }
        state.queue = state.queue.filter((entry) => now - entry.ts <= QUEUE_TTL_MS);
        if (changed) saveChannel(channel);
    }
}, 5 * 60_000);

function shutdown() {
    log('Shutting down');
    clearInterval(heartbeat);
    clearInterval(cleanup);
    for (const [channel] of channels) {
        saveChannel(channel, true);
    }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);