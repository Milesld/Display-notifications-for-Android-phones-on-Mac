# NotifyBridge 中继服务器

一个无第三方依赖的 Node.js TLS 中继，用于「手机在家、Mac 在外地」的云中转模式。服务器只转发**端到端加密**后的密文；它看不到通知正文，也不知道发送者/App。

## 它做什么

- 手机和 Mac 都用同一个中继密钥派生出的 channel + token 注册。
- 手机发来的密文按 channel 路由给 Mac。
- Mac 离线时排队（默认最多 500 条，7 天 TTL），重连后补发。
- Mac 解密成功并 ACK 后删除队列条目。
- 队列持久化到 `DATA_DIR/<channel>.json`，服务器重启不丢未送达消息。

不做什么：账号体系、Web 管理界面、推送通知（APNs/FCM）、明文存储。它只是一个小型存储转发服务。

## 要求

- Node.js 18+（无 npm 依赖）
- 一个域名 + TLS 证书（Let's Encrypt、Caddy、Nginx 均可）
- 一个可被手机和 Mac 访问的端口（默认 443）

## 快速测试（自签名证书）

```bash
./scripts/gen-relay-cert.sh localhost /tmp/nb-certs
PORT=18443 \
TLS_CERT=/tmp/nb-certs/relay-cert.pem \
TLS_KEY=/tmp/nb-certs/relay-key.pem \
DATA_DIR=/tmp/nb-relay-data \
node server/relay.js
```

Mac 端测试时允许自签名证书：

```bash
defaults write com.notifybridge.mac NotifyBridge.network.insecureTLS -bool true
```

**仅限本机测试。** 生产环境不要打开这个开关；用受信任的证书。

## 生产部署

### 1. 证书

最简单的方式是让 Node 直接持有 Let's Encrypt 证书：

```bash
sudo certbot certonly --standalone -d relay.example.com
```

然后按下面的 `TLS_CERT` / `TLS_KEY` 启动。证书续期后重启进程（或让 systemd 的 `ExecReload` 处理）。

**不要用 HTTP 反向代理**（Caddy 的 `reverse_proxy` / Nginx 的 `proxy_pass` 到 http）：NotifyBridge 中继不是 HTTP 服务。如果必须在前面放代理，只能用 TCP/stream 层（例如 Nginx `stream` + `ssl_preread` 做 TLS 透传，或 HAProxy `mode tcp`），并且保持端到端 TLS。

### 2. 启动

```bash
PORT=8443 \
TLS_CERT=/etc/letsencrypt/live/relay.example.com/fullchain.pem \
TLS_KEY=/etc/letsencrypt/live/relay.example.com/privkey.pem \
DATA_DIR=/var/lib/notifybridge \
node server/relay.js
```

如果前面用 Nginx `stream` / HAProxy 做 TLS 透传，Node 仍然需要 `TLS_CERT`/`TLS_KEY`。如果想让代理终止 TLS，后端这一跳也必须用 TLS，而普通 HTTP 反代不能承载这个协议；最省事的方式仍是让 Node 直接持有公网证书。

### 3. systemd

```ini
[Unit]
Description=NotifyBridge relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=notifybridge
Group=notifybridge
WorkingDirectory=/opt/notifybridge
Environment=PORT=8443
Environment=TLS_CERT=/etc/letsencrypt/live/relay.example.com/fullchain.pem
Environment=TLS_KEY=/etc/letsencrypt/live/relay.example.com/privkey.pem
Environment=DATA_DIR=/var/lib/notifybridge
ExecStart=/usr/bin/node /opt/notifybridge/server/relay.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/notifybridge

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --home /var/lib/notifybridge --shell /usr/sbin/nologin notifybridge
sudo install -d -o notifybridge -g notifybridge -m 700 /var/lib/notifybridge
sudo systemctl daemon-reload
sudo systemctl enable --now notifybridge
```

### 4. 防火墙

只开放 443（或你选的端口）。不要开放手机上的 47821；那是局域网/Tailscale 直连用的，不应该暴露到公网。

```bash
sudo ufw allow 443/tcp
```

## 客户端配置

在 Android「通知桥」→「网络与中继设置…」：

1. 点「生成新密钥」，复制 43 位密钥。
2. 填写中继地址，例如 `relay.example.com:443`。
3. 勾选「启用云中转」，保存。

在 Mac「通知桥」→「网络与中继设置…」：

1. 勾选「启用云中转」。
2. 填写同一个地址。
3. 粘贴同一密钥，保存。

两端状态分别显示「云中转：已连接」。Mac 可以在通知中心看到测试消息。

## 测试

```bash
cd server
npm test
```

测试会生成临时自签名证书、启动真实 TLS 服务，验证注册、在线转发、离线排队、ACK 和重启后队列持久化。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PORT` | `8443` | 监听端口 |
| `TLS_CERT` | `server/certs/relay-cert.pem` | 证书链 |
| `TLS_KEY` | `server/certs/relay-key.pem` | 私钥 |
| `DATA_DIR` | `server/data` | 队列持久化目录 |
| `MAX_QUEUE` | `500` | 每个 channel 最大排队条数 |
| `QUEUE_TTL_MS` | `604800000`（7 天） | 队列 TTL |

## 协议

见 [docs/network.md](../docs/network.md)。摘要：

```text
register   {role, channel, token, name}
deliver    {id, payload}          // payload 是 AES-GCM 密文
message    {id, payload}          // 服务器 → Mac
stored     {id}                   // 已入队/已转发
ack        {id}                   // Mac 确认
delivered  {id}                   // 服务器 → 手机
ping/pong
```

帧格式是 4 字节大端长度 + UTF-8 JSON，最大 1 MiB。

## 安全说明

- 服务器只保存 channel、token、密文、消息 ID 和时间戳。
- token 是 channel 的访问凭证；泄露 token 可以让别人向该 channel 发消息，但不能解密已有内容。怀疑泄露时在手机上重新生成密钥（新 channel）。
- 没有账号系统，也没有速率限制之外的滥用防护；建议只给自己和信任的人使用。
- 日志不打印 payload 或 token。
