# NotifyBridge BLE 协议 v1

手机端是 BLE GATT server（外设），Mac 端是 BLE central（中心设备）。这样 Android 只需要广播服务，Mac 主动连接；不依赖经典蓝牙串口（SPP），也不需要互联网。

## GATT 服务

| 用途 | UUID | 属性 |
| --- | --- | --- |
| 服务 | `9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D01` | Primary |
| TX（手机 → Mac） | `9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D02` | Notify |
| RX（Mac → 手机） | `9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D03` | Write |
| CCCD | `00002902-0000-1000-8000-00805f9b34fb` | TX 的订阅描述符 |

手机主广播包含 128-bit 服务 UUID，Mac 使用服务 UUID 过滤扫描。

扫描响应里带一段 Manufacturer Data，用于稳定识别同一台手机：

```text
company ID: 0xFFFF（little-endian: FF FF）
payload:    8 字节随机设备标识（安装 App 时生成，保存在手机私有设置中）
```

Android 的 BLE 地址会轮换，CoreBluetooth 的 peripheral UUID 也可能变化，因此不能只靠 UUID 记住手机。Mac 把这段 8 字节标识与配对信息一起保存，重连时按它匹配。

## 帧格式

BLE 默认 ATT 通知载荷为 20 字节。每条 JSON 消息被拆成有序的帧，每帧最多 16 字节内容：

```text
偏移  长度  含义
0     1     魔数 0x4E（ASCII "N"）
1     1     flags：bit0 = START，bit1 = END
2     2     序号，little-endian
4     N     UTF-8 JSON 片段，N <= 16
```

- 单帧消息的 flags = `0x03`。
- 多帧消息第一帧置 START，最后一帧置 END。
- 同一消息的所有帧使用相同序号；下一消息序号递增（允许 16-bit 回绕）。
- 接收端在 START 时清空缓冲，序号不匹配或超过 64 KiB 时丢弃当前消息。
- BLE 对同一 characteristic 的 notification 保证顺序，因此不需要包序号乱序重排。

实现参考：`macos/Sources/NotifyBridgeCore/Protocol.swift`、`android/app/src/main/java/com/notifybridge/app/BleProtocol.kt`。

## JSON 消息

### 手机 → Mac：通知

```json
{
  "v": 1,
  "type": "notification",
  "id": "0|com.tencent.mm|12345|null|10123",
  "app": "微信",
  "pkg": "com.tencent.mm",
  "title": "张三",
  "text": "晚上一起吃饭吗？",
  "time": 1700000000000,
  "category": "msg"
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `v` | 是 | 协议版本，当前为 1 |
| `type` | 是 | `notification` |
| `id` | 是 | 通知标识，用于 Mac 通知去重/替换 |
| `app` | 是 | 应用显示名，如「微信」「信息」 |
| `pkg` | 是 | Android 包名 |
| `title` | 否 | 会话名/发件人/标题 |
| `text` | 否 | 通知正文 |
| `time` | 是 | 手机通知时间，Unix 毫秒 |
| `category` | 否 | Android Notification category |

手机端会跳过 group summary、ongoing 通知和不可清除通知。

### 通知更新与去重

- `id` 使用 Android 的稳定 notification key（不带 postTime）。同一个会话/通知更新时，Mac 会更新同一张 macOS 通知卡片，而不是再叠一张。
- 旧版 Android 发送的 `id` 末尾带 `:postTime`；Mac 会识别并去掉 13 位毫秒时间戳，所以升级 Mac 端也能兼容旧 APK。
- 如果通知带 `EXTRA_MESSAGES`（MessagingStyle），手机端按消息的 `time` 字段选**时间最新**的一条，而不是假设数组顺序。
- 手机端按 notification key 记录上一条消息的时间；更新里没有更新的消息时间时直接丢弃，避免“旧短信又提醒一次”。
- 同一内容 3 秒内去重；Mac 端另有 2 秒的完全相同内容去重，作为双保险。

### 手机 → Mac：状态

```json
{"v":1,"type":"status","state":"waiting_for_pin","detail":"请输入手机上的 6 位配对码"}
```

状态值：

- `waiting_for_pin`：Mac 已订阅，等待配对。
- `paired`：配对成功，可以开始转发通知。
- `pairing_failed`：配对码错误。

### Mac → 手机：配对

```json
{"v":1,"type":"pair","pin":"123456","client":"notifybridge-macos"}
```

也用同样的帧格式写在 RX characteristic 上（with response）。

### Mac → 手机：心跳

```json
{"v":1,"type":"ping","time":1700000000000}
```

Mac 在已订阅 TX 后每 8 秒写一次心跳。手机把任何一次 RX 写入都视为“Mac 还在连接范围内”，并每 4 秒检查一次：

- 超过 30 秒没有收到 Mac 的写入，手机主动取消 GATT 连接并重新开始广播。
- 这一条用于处理“手机已经在范围外，但 Android 没及时收到 disconnect 回调”的情况，避免手机界面一直显示已连接。
- Mac 侧同时有 12 秒写入超时：写入未完成就取消连接并重新扫描。
- 手机端还有一个 8 秒 TX callback 超时。如果 Android 没有收到 `onNotificationSent`，会主动取消连接，让 Mac 自动重连，避免通知发送队列卡死后永久收不到消息。

## 连接与配对流程

1. 手机 App 启动前台服务，添加 GATT 服务并开始可连接广播。
2. 首次使用时，Mac 按服务 UUID 扫描到手机，用户点击「连接手机」并输入手机上的 6 位配对码。
3. Mac 连接、发现服务，订阅 TX 的 CCCD。
4. 手机收到订阅后发送 `waiting_for_pin`。
5. Mac 把 `pair` 帧写入 RX，然后每 8 秒发送 `ping`。
6. 手机校验配对码，成功则发送 `paired`，之后只转发处于已配对会话的通知。`paired` 的 `detail` 会带上 `notifications=on/off`，Mac 可以显示手机通知访问是否正常。
7. 断开连接会清除手机端本次会话的授权；重新连接时，Mac 自动使用保存的配对码重新完成上面的配对，因此用户不需要再次输入。配对码可通过手机 App 刷新，刷新后 Mac 的旧配对码失效，需要手动重新配对。
8. 连续 5 次配对码错误时，手机会主动断开连接。
9. 如果首次连接时手机恰好轮换了 BLE 地址，CoreBluetooth 会返回 `Device is invalid`；Mac 保留刚输入的配对码，自动重新扫描并重试一次，不需要用户再输入第二次。
10. 手机离开范围后，Mac 扫描、手机重新广播；双方恢复后自动连接。
11. 手机蓝牙关闭再打开时，服务会重新注册 GATT 并广播；Mac 继续扫描并自动连接。

## 网络通道（v2）

BLE 之外还有两条网络路径，协议细节见 [network.md](network.md)：

- **直连 TCP**：局域网（Bonjour 发现）和 Tailscale（手动地址）共用手机上的 `47821` 端口。帧格式是 4 字节大端长度 + JSON；配对复用 6 位 PIN；服务端保留最近 500 条通知，Mac 在 `auth` 中带 session/last seq，重连后补发并逐条 ACK。
- **云中转**：手机和 Mac 各自主动连接 TLS 中继，用中继密钥派生 channel/token/AES-GCM key；服务器只转发密文并按 channel 离线排队，Mac 解密成功后才 ACK。

Mac 同时运行 BLE、直连和（可选）云中转，通知按「稳定 ID + 手机发送时间」去重，因此多通道在线不会重复弹窗。

## 安全边界

当前 MVP 的配对码由手机通过未加密的 BLE 链路接收，只能防止附近的人随手连接，不能抵抗被动窃听或主动中间人攻击。通知正文同样在 BLE 链路上明文传输。

为了实现自动重连，Mac 会把 6 位配对码保存在本机应用偏好设置中（未使用 Keychain 加密）。这台 Mac 的用户账号下的其他进程理论上可以读取它。它只在本机、BLE 范围内有效，但这仍然不是生产级密钥管理。

默认情况下内容只在手机与 Mac 之间传输；启用云中转后，中继只看到端到端加密后的密文。若要用于敏感场景，建议：

- 使用 LE Secure Connections 绑定，或在应用层做 ECDH + AES-GCM 会话加密。
- 不要把配对码直接写在 RX 上，改为 challenge-response。
- 每台 Mac 使用独立密钥，保存在 Android Keystore / macOS Keychain，并加入生物识别/访问控制。
- 增加连接设备列表、撤销配对、重放保护。
- 为心跳与自动重连增加设备身份签名，防止伪造广播。

在完成这些之前，应把本项目视为局域网/近距离范围内的个人原型，而不是企业级安全产品。
