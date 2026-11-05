# 网络通道：局域网、Tailscale 与云中转

BLE 仍然是默认路径，手机在 Mac 旁边时优先走蓝牙。网络通道是**附加**的：手机离开蓝牙范围后，Mac 会自动改用同一个 Wi-Fi、Tailscale，或自建云中转继续收通知。

## 三条路径

| 路径 | 适用场景 | 需要什么 | 加密 |
| --- | --- | --- | --- |
| 蓝牙 | 手机在 Mac 旁边（约 10 米内） | 蓝牙 | BLE 链路，应用层明文 |
| 局域网 | 手机在家，Mac 也在同一个 Wi-Fi | 同一个局域网；Bonjour/mDNS | 局域网内明文（与蓝牙一致） |
| Tailscale / 远程直连 | 手机在家，Mac 在公司或外地 | 两端登录同一个 tailnet；Mac 填手机 Tailscale 地址 | WireGuard（Tailscale 负责） |
| 云中转 | 没有 tailnet，或需要 Mac 离线期间排队 | 一台可访问的 TLS 中继服务器 | TLS + 端到端 AES-GCM |

局域网和 Tailscale 共用手机上的同一个 TCP 服务（端口 `47821`）。区别只是 Mac 通过 Bonjour 自动发现，还是手动填写 Tailscale 地址。云中转是另一条独立通道，手机和 Mac 都主动外连服务器。

## 自动切换

Mac 端会同时运行蓝牙、直连和云中转（后者配置后才启用），不会因为一条通道可用就关闭其他通道：

- 任何一条通道到达的通知都会进入同一个通知中心入口。
- 通知用「手机端稳定 ID + 手机发送时间」去重，所以同一条消息从蓝牙和网络同时到达时只弹一次。
- 真正的新消息（同一会话的新 post time）不会被去重掉。
- 菜单栏「状态」显示当前可用的路径，例如「已连接：蓝牙 + 局域网 + 云中转」。
- 某条路径断开后按 2/5/15/30/60/120 秒退避重连；手动「重新连接网络通道」会立即重试。

手机端不需要切换：BLE GATT server、TCP 服务和云客户端可以同时运行。每条通知会分别尝试所有已启用的通道。

## 直连 TCP 协议

手机是服务端，Mac 是客户端，和 BLE 的角色一致。

```text
4 字节大端长度 N
N 字节 UTF-8 JSON
```

最大帧 256 KiB。消息类型：

| 方向 | 类型 | 说明 |
| --- | --- | --- |
| 手机 → Mac | `hello` | 连接后立即发送设备 ID、名称、服务端 session |
| Mac → 手机 | `auth` | 6 位配对码，可带上次的 session 和 last seq |
| 手机 → Mac | `auth_ok` | 配对成功，返回通知访问状态、当前 head、session |
| 手机 → Mac | `auth_fail` | 配对码错误；同一连接连续 5 次后断开 |
| 手机 → Mac | `notification` | `seq` + 原始通知 JSON（`data`） |
| Mac → 手机 | `ack` | 已处理到该序号 |
| 双向 | `ping` / `pong` | 心跳；手机 45 秒无数据会关闭连接 |

### 断线补发

手机保留最近 500 条通知的环形历史。Mac 在 `auth` 里带上次的 session 和 last seq；如果 session 相同，手机会把 seq 更大的通知补发过来。Mac 每收到一条就 ACK，并持久化 last seq。

- 手机服务重启后 session 变化，Mac 会从当前 head 重新开始，不会把旧历史全部重放。
- Mac 首次配对不发送 `since`，避免第一次连接就收到 500 条旧通知。
- 局域网断开、Mac 睡眠、Wi-Fi 切换后，重连即可补上这段时间的通知。

### 发现

手机通过 Android `NsdManager` 广播 `_notifybridge._tcp`，TXT 包含 `id`（8 字节设备 ID 的十六进制）和 `name`。Mac 用 `NWBrowser` 浏览，按已配对设备 ID 过滤；找不到时回退到「网络与中继设置」里填的远程地址。

## 云中转协议

```text
Android 手机 ── TLS ──► relay.example.com:443 ◄── TLS ── Mac
```

两端都用同一个「中继密钥」（32 字节，手机端生成，43 位 Base64URL）注册：

```text
channel = HKDF-SHA256(secret, salt="NotifyBridge-v1", info="channel", 16)  // 16 字节 hex
token   = HKDF-SHA256(secret, salt="NotifyBridge-v1", info="auth",   32)  // Base64URL
encKey  = HKDF-SHA256(secret, salt="NotifyBridge-v1", info="enc",    32)  // 不发给服务器
```

- 服务器只保存 `channel` 和 `token`，不接触 `encKey`。
- 通知信封（`type/seq/session/data`）用 AES-256-GCM 加密，AAD 是 channel 字符串。
- 服务器只看到随机消息 ID、密文、时间戳和在线状态；看不到发送者、App、标题或正文。
- 服务器按 channel 维护一个离线队列（默认 500 条，7 天 TTL），Mac 重连后补发；Mac 解密成功后才 ACK，ACK 后服务器删除队列条目。
- 手机发送后保留 pending，收到服务器的 `delivered` 才删除；重连会重发，服务器按消息 ID 去重。

> 端到端加密的强度取决于「中继密钥」的保密程度。它等同于账号密码：不要发到公开频道；怀疑泄露时在手机上重新生成，并在 Mac 上重新粘贴。更换密钥会创建新的 channel，旧队列不会迁移。

## Tailscale 配置

1. Android 安装 Tailscale，登录；在系统设置里允许 always-on VPN，并把通知桥加入电池优化白名单。
2. Mac 安装 Tailscale，登录同一个 tailnet。
3. 找到这台手机的 tailnet 地址（下面三种方法任选）。
4. Mac 菜单栏 →「网络与中继设置…」→ 勾选「启用局域网 / 远程直连」，填写 `手机地址:47821`。
5. 手机端保持「启动同步」。首次仍需要 6 位配对码；配对信息会复用蓝牙保存的 PIN。

### 怎么查看手机的 tailnet 地址

**最稳妥：Tailscale 管理后台**

1. 浏览器打开 <https://login.tailscale.com/admin/machines>（登录同一个 tailnet）。
2. 在 Machines 列表里按设备名找到手机（通常是 `pixel-8`、`Xiaomi-14` 之类）。
3. 点击该设备展开详情，能看到：
   - **Tailscale IP**：`100.x.y.z`（100.64.0.0/10 网段）。
   - **MagicDNS name**：类似 `pixel-8.tailnet-abc123.ts.net`（需要 tailnet 开启 MagicDNS）。
4. 点旁边的复制按钮，带回 Mac。

**Android Tailscale App**

打开 Tailscale，进入设备/这台手机的详情页；不同版本入口略有差异，通常在「This device」或右上角设备列表里。详情页会显示这台手机的 `100.x.y.z` 地址，部分版本可以直接复制。找不到就以管理后台为准。

**在 Mac 上查**

如果 Mac 装了带 CLI 的 Tailscale 版本（Homebrew 或独立 App），可以在终端执行：

```bash
tailscale status
tailscale ip -4 手机设备名
```

`tailscale status` 会列出 tailnet 里的设备、100.x 地址和 MagicDNS 名称；第二列通常就是设备名。App Store 版本可能没有把 `tailscale` 命令放进 PATH，这时用管理后台。

### 填哪种地址

两种都行，Mac 的输入框接受 `host:port`：

```text
100.101.102.103:47821
pixel-8.tailnet-abc123.ts.net:47821
```

- **MagicDNS 名称**更稳定，设备重装 Tailscale 后通常不变；需要 tailnet 开启 MagicDNS。
- **100.x IP** 不依赖 MagicDNS，但设备移除/重装后可能变化。
- 不要填手机在家里 Wi-Fi 的 `192.168.x.x`，也不要加 `https://` 或结尾斜杠。

### 验证

在 Mac 终端：

```bash
tailscale ping 手机设备名          # 先确认 tailnet 能通
nc -vz 手机地址 47821            # 再确认通知桥端口能连
```

- `tailscale ping` 不通：手机 Tailscale 没在线、两端不在同一 tailnet，或 ACL 不允许。
- `nc` 显示 `succeeded`：端口可达，Mac App 里保存后应能自动配对。
- `Connection refused`：Tailscale 通了，但手机上的「通知桥」同步服务没启动。
- 超时：检查 Tailscale ACL 是否允许 Mac 访问手机的 `tcp:47821`，以及手机是否把通知桥加入了电池优化白名单。

Tailscale 路径的流量由 WireGuard 加密，应用层协议是明文，和局域网模式一致。若 ACL 禁止入站，Mac 会连不上；需要允许 Mac 访问手机的 47821 端口。

## 云中转部署

见 [server/README.md](../server/README.md)。最短路径：

```bash
./scripts/gen-relay-cert.sh relay.example.com
TLS_CERT=server/certs/relay-cert.pem \
TLS_KEY=server/certs/relay-key.pem \
PORT=443 DATA_DIR=/var/lib/notifybridge node server/relay.js
```

生产环境建议用 Caddy/Nginx 终止 TLS，或给 Node 进程一个 Let's Encrypt 证书；只开放 443，不要暴露手机上的 47821。

## 安全边界

- 蓝牙和局域网直连都是应用层明文；它们只适合你信任的近距离网络。Tailscale 由 WireGuard 加密。
- 云中转的 TLS 保护传输，AES-GCM 保护内容；服务器仍能看到连接时间、channel 和消息大小。它不是匿名网络。
- 中继密钥、配对码都保存在设备本地偏好设置里，没有 Keychain/Keystore 生物识别保护。能登录本机账号的进程理论上可以读取。
- 没有做证书固定（certificate pinning）；云中转依赖系统信任链。自签名证书只应在测试时使用 `NotifyBridge.network.insecureTLS`。
- 这是一个自用原型，不是企业级消息网关。

## 已知限制

- 手机必须开机、有电、联网；短信/微信仍然先到手机。手机不在线时，云中转只能补发它已经收到的通知。
- 网络通道复用了原来的前台服务，Android 启动流程仍要求蓝牙权限和蓝牙开关；不需要蓝牙连接，但需要保留这些权限/开关。
- Android 厂商的后台限制可能杀掉前台服务；需要电池优化白名单。部分 ROM 还会限制 Wi-Fi 休眠或 mDNS。
- 云中转服务器重启会保留队列文件，但内存中的在线状态会丢失，两端会自动重连。
- 局域网 mDNS 在开启 AP 隔离、访客网络或某些企业 Wi-Fi 下不可用；此时用 Tailscale/手动地址或云中转。
- 当前没有实现通知点击跳回手机、快捷回复、通知撤销同步。
