# 通知桥 NotifyBridge

<img src="assets/AppIcon-1024.png" width="96" align="right" alt="通知桥 App 图标" />

把 Android 手机收到的新通知（短信、微信、其他 App）通过**低功耗蓝牙**转发到 Mac，并在 macOS 通知中心显示标题和正文。

这是一个可运行的原型：Android 手机作为 BLE 外设广播通知，Mac 作为 BLE 中心设备接收。首次配对后，手机离开范围再回来、Mac 重启，都会自动重连。**不经过互联网，不需要同一 Wi-Fi。**

---

## 先说结论：iPhone 能不能做？

**不能做通用的第三方 App。** 这不是技术难度问题，而是平台限制：

- iPhone 没有向第三方 App 开放“读取其他 App 通知”的公开 API。App Store 审核也不允许应用读取系统通知或其他 App 的内容。
- 苹果自己的「iPhone 镜像」可以在 Mac 上显示 iPhone 通知，但那是系统 Continuity 功能，第三方无法调用。
- Apple 的 ANCS（Apple Notification Center Service）是面向蓝牙配件的通知服务，不是给普通 Mac App 读取 iPhone 通知的公开接口，也不能覆盖微信等所有 App。
- 越狱或私有 API 可以绕过，但不适合作为产品，也不在本项目范围内。

**Android 可以。** Android 提供了 `NotificationListenerService`，用户明确授权后，应用可以读取通知栏中的通知（包括短信和微信通知，前提是通知本身显示了内容）。KDE Connect、Phone Link 等产品也是这个原理。

本项目实现的是：

| 手机 | 支持情况 |
| --- | --- |
| Android 8.0+（带 BLE 广播） | ✅ 本仓库 |
| iPhone | ❌ 无第三方公开接口；使用系统「iPhone 镜像」 |
| HarmonyOS 4 及以下（兼容 APK） | ⚠️ 未测试，可能可用 |
| HarmonyOS NEXT | ❌ 不运行 APK |

---

## 它长什么样

- **Android 端**：打开通知访问 → 启动同步 → 显示 6 位配对码；前台服务保持 BLE 广播，断线后自动恢复广播。
- **Mac 端**：菜单栏图标 → 首次输入配对码；之后新通知以 macOS 横幅显示，断线后自动重连。
- 不显示 Dock 图标（`LSUIElement`），只占菜单栏。
- 通知内容格式：标题为发件人/会话，副标题为 App 名称，正文为消息内容。

示例：

```text
张三
微信
晚上一起吃饭吗？
```

### 界面预览

以下截图来自 Android 15 模拟器，服务已启动并在等待 Mac 连接（模拟器的虚拟蓝牙没有桥接到宿主机，所以没有完成真实连接）：

| 首页 | 配对码 |
| --- | --- |
| <img src="assets/android-running.png" width="300" alt="Android 首页" /> | <img src="assets/android-pairing.png" width="300" alt="Android 配对码" /> |

---



## 架构

```text
┌──────────────────────────── Android ────────────────────────────┐
│  NotificationListenerService                                    │
│    └─ 过滤 group summary / ongoing / 重复通知                     │
│    └─ 读取 EXTRA_TITLE / EXTRA_TEXT / MessagingStyle             │
│                    │ JSON                                       │
│                    ▼                                            │
│  FrameCodec：4 字节头 + 16 字节内容，拆成 20 字节 BLE 通知帧       │
│                    │                                            │
│  BluetoothGattServer（外设）                                     │
│    ├─ TX characteristic：Notify → Mac                            │
│    ├─ RX characteristic：Write ← Mac（配对码 / 心跳）             │
│    └─ 扫描响应：Manufacturer Data = 8 字节稳定设备 ID             │
└────────────────────────────┬────────────────────────────────────┘
                             │ BLE（无互联网）
┌────────────────────────────▼────────────────────────────────────┐
│  macOS 菜单栏 App（CBCentralManager）                             │
│    ├─ 扫描服务 UUID + 设备 ID → 自动连接                          │
│    ├─ 订阅 TX，发送保存的配对码；每 8 秒写一次心跳                 │
│    ├─ 重组帧 → 解码 JSON → UNUserNotificationCenter              │
│    └─ 断线后持续扫描，发现同一设备后自动恢复                      │
└─────────────────────────────────────────────────────────────────┘
```

BLE 服务与 TX/RX 的 UUID、帧格式、JSON 字段和配对流程见 [docs/protocol.md](docs/protocol.md)。

---

## 快速开始

### 0. 直接用已经打好的包

本仓库的 `dist/` 目录包含：

- `NotifyBridge-macOS-0.1.0.dmg`：Mac 安装包（Apple Silicon）。
- `NotifyBridge-macOS-0.1.0.zip`：同样的 `.app` 压缩包。
- `NotifyBridge-Android-0.1.0-debug.apk`：可直接安装的 Android debug 包。
- `SHA256SUMS.txt`：三个产物的校验和。

Mac 端没有经过 Apple 公证（ad-hoc 签名），首次打开如果被 Gatekeeper 拦住，右键 App →「打开」。Android 包使用 debug 签名，适合自用测试，不适合上架。

### 1. 构建并启动 Mac 端

要求：macOS 13+，已安装 Xcode Command Line Tools（`xcode-select --install`）。

```bash
./scripts/build-macos.sh
open dist/NotifyBridge.app
```

首次启动会请求两个权限：

1. **蓝牙**：用于扫描和连接手机。
2. **通知**：用于在 Mac 上显示同步过来的消息。

如果通知权限被拒绝，菜单栏「通知权限：未开启」可以打开系统设置。也可以先点「发送测试通知」验证 Mac 端显示链路。

App 是本地 ad-hoc 签名，放在 `dist/NotifyBridge.app`。拷贝到 `/Applications` 也可以。**每次重新构建后 ad-hoc 签名会变化，macOS 可能重新弹出蓝牙授权**；必须点「允许」，否则 App 会停在初始化状态、无法扫描。

运行时日志：`~/Library/Logs/NotifyBridge.log`。

> 如果「通知权限」显示未开启，请到系统设置 → 通知 → 通知桥 打开允许通知；菜单里的「通知权限设置…」可以直接跳转。

### 2. 构建 Android 端

要求：

- JDK 17
- Android SDK Platform 35、Build Tools 34.0.0 或 35.0.0
- Gradle 8.9+（或 Android Studio）

```bash
cd android
# 如果没有设置 ANDROID_HOME，创建 local.properties：
# echo "sdk.dir=/path/to/Android/sdk" > local.properties
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

> 项目包含标准的 Gradle Wrapper 8.9（`gradlew` + `gradle/wrapper/gradle-wrapper.jar`）。首次运行会下载官方 Gradle 8.9；也可以直接用 Android Studio 打开 `android/`。

本项目的开发环境已经完成 APK 构建、aapt 清单检查、单元测试，并在实体 Android 手机上验证过 BLE 配对与通知转发。自动重连需要同时安装本次更新后的 Android APK 和 Mac App（见“验证状态”）。

### 3. 在手机上设置

1. 安装并打开「通知桥」。
2. 点「去授权」，在系统设置里允许「通知桥」读取通知。
3. 回到 App，点「启动同步」。
4. 如果系统弹出蓝牙/附近设备权限，选择允许。
5. 记下屏幕上的 6 位配对码。

### 4. 在 Mac 上连接

1. 点击菜单栏的「通知桥」图标。
2. 选择「连接手机」。
3. 输入手机上的 6 位配对码。
4. 菜单显示「已连接并已配对，自动重连已开启」后，让手机收到一条新消息即可测试。

首次配对成功后，Mac 会把配对码和这台手机的稳定 ID 保存在本机。之后：

- 手机走出蓝牙范围再回来：Mac 自动扫描并连接，自动重新配对。
- Mac 重启、App 重启：自动连接。
- 手机蓝牙关掉再打开：旧版手机 App 需要手动重启同步；新版会监听蓝牙状态并重新广播。
- 手动点「断开连接」会暂停自动重连；再点「连接手机」并配对后恢复。
- 手机 App 里刷新配对码会让 Mac 保存的旧码失效，需要手动重新输入新码。

Mac 端也可以通过「发送测试通知」只测试本机通知权限，不需要手机。

---

## 验证状态

已经在本机验证：

- `swift build` 编译 macOS 端成功。
- `swift run ProtocolSelfTest`：帧拆分/重组、UTF-8、序号错误、JSON 编解码全部通过。
- macOS `.app` 打包、ad-hoc 签名和 `codesign --verify` 通过。
- App 可启动，菜单栏进程正常，CoreBluetooth 进入 poweredOn 并开始扫描。
- Android 工程在本机用 JDK 17 + Android SDK 35 + Gradle 8.9 构建成功；`FrameCodecTest` 6/6、`NotificationMergeTest` 4/4 通过。
- 已用 aapt2 检查 APK：包名、minSdk 26、targetSdk 35、通知监听组件、BLE 权限均存在；**没有申请 INTERNET 权限**。
- 在 Android 15 模拟器（API 35）上安装并启动成功：通知访问授权生效、通知监听服务收到系统通知、前台服务运行（`foregroundServiceType=connectedDevice`），BLE 广播成功，UI 显示「等待 Mac 连接」。
- 使用实体 Android 手机与 Mac 完成了真实的 BLE 配对和通知转发：短信、微信通知均成功到达 Mac。
- 自动重连：预置配对信息后重启 Mac App，App 在扫描到手机后**无需点击**自动连接并自动发送配对码；故意使用错误配对码时，手机会返回配对失败，Mac 会清除失效的配对信息，符合预期。
- 重复通知修复：Android 改用稳定 notification key 作为 ID、按消息时间选择最新短信、跳过没有更新消息时间的通知更新；Mac 兼容旧 ID 并增加 2 秒相同内容去重。相关 ID 归一化测试已通过，APK/Mac App 均已重新构建。
- 首次连接失败修复：日志确认首次连接报 `Device is invalid`（手机轮换 BLE 地址后缓存对象失效），第二次才成功。新版会选择最近扫描对象、按稳定 ID 替换旧对象，并在连接失败时保留配对码自动重扫重试一次。
- 次日重连风暴修复：日志显示旧版在 Mac 睡眠/蓝牙反复开关期间持续连接弱信号手机，最终报 `maximum number of connections for this client`。新版增加指数退避、连接数上限 2/5 分钟冷却、弱信号（< -88 dBm）不自动连接、以及退避期间停止扫描。
- 连接后无通知诊断：Mac 端配对成功后会显示手机通知访问是否开启；手机端新增「发送测试消息到 Mac」按钮，可区分“BLE 通道问题”与“手机通知监听/授权问题”。Android 发送通知帧新增 8 秒 watchdog，避免发送队列卡死后永久无通知。
- 通知权限诊断：macOS 系统日志显示通知已按 banner 投递（`Presenting ... as banner`），但被当前启用的专注模式以 `DND suppression: delay` 暂缓，因此只进入通知中心。系统设置中的通知桥样式为「横幅」。
- 已生成 macOS DMG/ZIP 和 Android APK，校验和见 `dist/SHA256SUMS.txt`。

尚未验证：

- 新版心跳/30 秒断线检测在实体手机上的完整表现（旧 APK 没有心跳，需要安装新版 APK 后验证手机端自动显示断开）。
- “首次配对码自动重试”和“连接后无通知”的实机闭环：代码已编译、安装在模拟器验证；实体手机上的最终表现需要你在安装新 APK 后测试。
- 成功自动重连后的稳定 ID 匹配：本次自动连接测试使用的是旧 APK（无 Manufacturer Data），通过“首次迁移”路径自动连接；稳定 ID 广播已实现并可在 Android 模拟器启动，但还没有在实体手机上完成一次“新版手机 + 新版 Mac”的自动重连闭环。
- 不同厂商（小米、OPPO、vivo、华为等）的后台保活和通知字段差异。
- iPhone（不支持，见上）。
- Mac 构建为 Apple Silicon（arm64）版本，未生成 Intel 通用二进制。

> APK 路径：`dist/NotifyBridge-Android-0.1.0-debug.apk`  
> Android 单元测试：`android/app/src/test/java/com/notifybridge/app/FrameCodecTest.kt`、`NotificationMergeTest.kt`

---

## 常见问题

### 为什么微信只显示「你收到一条新消息」？

微信或系统把通知内容隐藏了。常见原因：

- 微信设置中关闭了“通知显示消息详情”。
- 手机锁屏通知设置为“隐藏内容”。
- 微信使用了不包含正文的自定义通知。
- 部分厂商系统会对通知正文做脱敏。

通知桥只能转发通知栏里实际存在的内容，不能读取微信数据库或聊天记录。

### 手机上的旧短信没清，Mac 会重复提醒旧短信？

这是因为旧实现把 `postTime` 拼进了通知 ID，导致同一条 SMS 通知每次更新都被 Mac 当成一条新通知；同时有些短信 App 的 MessagingStyle 消息数组是“新消息在前”，旧实现取最后一条时会取到旧短信。

新版的处理：

- Android 的 `id` 改用稳定的 notification key；同一会话更新会**替换** Mac 上的旧通知卡片。
- 手机端按消息时间选择最新的一条，不再依赖数组顺序。
- 按会话记录上一条消息时间；没有新消息的更新直接丢弃。
- Mac 端兼容旧 APK 的 `:postTime` 后缀，并额外做 2 秒相同内容去重。
- 手机和 Mac 都需要安装本次更新后的版本；只更新一端无法同时获得最新消息选择和稳定 ID 两项修复。

### 已经显示连接完成，但 Mac 不弹通知？

先按这个顺序排查：

1. **手机通知访问是否还在**：新版 APK 覆盖安装/卸载重装后，系统可能撤销「通知访问」。打开手机上的「通知桥」，第 1 步必须显示「已授权，通知桥可以读取新通知」。
2. **看 Mac 菜单栏状态**：如果显示「已连接并已配对，但手机通知访问未开启」，直接去手机重新授权即可。
3. **点手机上的「发送测试消息到 Mac」**：
   - 测试消息能到 Mac：说明 BLE 通道正常，问题在手机通知监听权限或来源 App 的通知设置。
   - 测试消息也到不了：查看 Mac 菜单状态和 ~/Library/Logs/NotifyBridge.log，可能需要重新连接。
4. **检查 Mac 的专注模式和通知样式**，原因见上一节。

另外，新版在发送通知帧后有一个 8 秒看门狗。如果 Android 的通知发送回调卡住，手机会主动断开重连，避免出现“已连接但永远不再发通知”的状态。

### 首次输入配对码没反应，第二次才行？

核心原因是手机轮换 BLE 地址后，Mac 里缓存的 CBPeripheral 已失效，首次连接会立即报 `Device is invalid`。新版会：

- 丢弃旧地址的 peripheral，优先使用最近一次扫描到的对象；
- 首次连接失败时保留刚输入的配对码，自动重新扫描并重试一次，不需要再输第二遍。

### 第二天自动重连一直搜索/连接失败，像在轮询手机？

这次日志里的直接原因是：

```text
Connection failed: The system has reached the maximum number of connections for this client
```

Mac 在夜间多次睡眠/唤醒、蓝牙反复关闭再打开，旧版自动重连在每次发现手机后都会立即尝试连接。手机当时信号在 -90 ~ -103 dBm，连接很难成功；失败后旧版又立刻重扫、立刻重连，最终把 macOS 允许这个 App 使用的 CoreBluetooth 连接槽耗尽了。槽位满后，即使手机就在旁边，也会一直“发现手机 → 连接失败 → 重新搜索”。

新版做了这些限制：

- 连接失败后指数退避：2 → 5 → 15 → 30 → 60 → 120 → 300 秒，退避期间不扫描、不连接。
- 遇到 `maximum number of connections` 时暂停自动重连 2 分钟，重复出现则暂停 5 分钟，不再刷连接。
- 自动连接要求 RSSI 不低于 -88 dBm；信号太弱时等待手机靠近，避免隔着房间反复连接。
- 首次连接遇到失效 peripheral 只快速重试一次，其余失败进入退避。
- 手动点「连接手机」会重置退避并强制尝试一次。

如果升级后仍看到这个错误，先关闭再打开 Mac 蓝牙（或重启 Mac），然后重新打开通知桥；这是清理已经被旧版耗尽的连接槽最直接的方法。

### 为什么键盘、鼠标、触控板能秒连，手机不行？

它们和这个 App 走的是完全不同的路径：

- 键盘/鼠标是 **BLE HID 专用外设**，固件在断开时持续、低占空地广播；macOS 系统蓝牙栈直接管理配对、重连和休眠唤醒，不需要第三方 App。
- 通知桥的手机端是普通 Android App，必须由前台服务维持 GATT server/广播；Android 可能杀后台、限制广播，手机离开范围后也不像键盘固件那样始终在线。
- Mac 端通过 `CBCentralManager` 建立的是 **App 级 BLE 连接**，macOS 对每个 App 有连接数限制；HID 设备由系统守护进程管理，不占这个 App 的连接配额。
- 手机当时在 -100 dBm 左右，而键盘/鼠标通常就在 Mac 旁边；BLE 在弱信号下连接成功率差很多。

所以不能直接套用键盘/鼠标的 HID 逻辑来传通知。能借鉴的是它们的行为：稳定身份、弱信号不硬连、失败后退避、重试有上限。新版已经按这个思路改了；Android 端后续还可以加开机自启和电池优化白名单，进一步接近“常驻外设”的体验。

### 为什么 iPhone 不行，Android 却可以？

iOS 没有“通知监听”公开 API，第三方 App 只能处理自己的通知；Android 的 `NotificationListenerService` 是系统提供给用户授权后的通知访问接口。

### 为什么不用经典蓝牙串口（SPP）？

经典蓝牙 SPP 在 iPhone/iPad 上不支持，且跨平台实现差异大。BLE GATT 在 Android 和 macOS 上都稳定，功耗低，适合持续小数据量传输。代价是默认 20 字节 MTU，因此协议做了分帧。

### 连接安全吗？

- 内容只在手机和 Mac 的 BLE 链路传输，不经过互联网。
- 配对码有 6 位，连续错误 5 次会断开。
- 为了自动重连，Mac 会把配对码保存在本机应用偏好设置中（**未做 Keychain/生物识别保护**）。能登录这台 Mac 用户账号的进程理论上可以读到它。
- **当前 BLE 链路未做应用层加密**，配对码和通知正文在链路上是明文。它适合个人近距离使用，不适合传敏感信息或企业环境。生产化建议见协议文档的“安全边界”。

### 手机离开范围后会自动重连吗？

新版（Android + macOS 同时更新）会：

- 手机端在 30 秒收不到 Mac 心跳时，主动判断连接已断并重新广播。
- Mac 持续扫描，发现保存过的手机后自动连接，并自动重发配对码。
- Mac 重启、手机蓝牙重启后也会恢复。

注意：

- **需要安装新版 APK**。旧版手机端没有心跳，Mac 断开后它可能仍显示「Mac 已连接」，也不会及时重新广播。
- 手动点「断开连接」会暂停自动重连。
- 刷新手机上的配对码会让 Mac 保存的旧码失效，需要手动重新配对。
- 自动重连的开关在 Mac 菜单栏的「自动重连」；「忘记已配对手机」可以清除保存的配对信息。

### 为什么手机蓝牙断开后手机端没显示断开？

旧版手机端只依赖 Android 的 disconnect 回调，蓝牙链路在范围边缘可能长时间不回调。新版增加了双向心跳：Mac 每 8 秒写一次 RX，手机 30 秒收不到就主动取消连接并重新广播。因此升级新版 APK 后，手机端最多约 30 秒会显示断开并恢复等待连接。

### 更新后 App 好像卡住、没有扫描手机？

ad-hoc 签名每次构建都会变化，macOS 会把它当成新的二进制重新询问蓝牙权限。请：

1. 在系统弹窗中允许蓝牙；如果没看到弹窗，打开系统设置 → 隐私与安全性 → 蓝牙，允许「通知桥」。
2. 退出并重新打开通知桥。
3. 菜单状态应先变成「正在搜索附近的手机…」。

### 通知只在通知中心，没有桌面横幅？

如果 Mac 通知中心里能看到内容，说明通知已经成功投递。常见的“没有横幅”原因按顺序检查：

1. 系统设置 → 通知 → 通知桥：开启允许通知，样式选「横幅」或「提醒」。
2. **专注模式/勿扰模式**：这是最常见原因。专注模式会把横幅延迟，只放进通知中心。打开控制中心检查当前是否有专注模式，关闭它，或把「通知桥」加入该专注模式的允许通知。
3. 屏幕是否处于锁定/睡眠状态，以及通知设置中的锁屏显示选项。
4. 菜单栏「通知权限」是否显示为「仅通知中心」；如果是，点进去修改样式。

本机日志可以直接看出来：如果出现 `muted by DND suppression: delay` / `Resolved event behavior ... interruptionSuppression: delay delivery`，就是专注模式拦截了横幅，不是通知桥没有发送。

### 服务被手机系统杀掉了？

Android 厂商的后台策略差异很大。可以：

- 将「通知桥」设为“不受限制/允许后台运行”。
- 关闭该应用的电池优化。
- 保持通知访问权限和前台服务通知可见。
- 重新打开 App，启动同步。

### 为什么 Mac 收不到通知？

按顺序检查：

1. Mac 系统设置 → 通知 → 通知桥：允许通知，样式不是“无”。
2. 菜单栏状态是否为「已连接并已配对」。
3. 手机端是否显示「Mac 已连接并配对」。
4. 手机通知本身是否显示内容。
5. 查看 `~/Library/Logs/NotifyBridge.log` 是否有连接/投递错误。

---

## 目录结构

```text
android/                       Android 客户端（Kotlin，无第三方运行时依赖）
  app/src/main/java/...        Activity、通知监听、BLE 服务、帧协议
macos/                         macOS 接收端（Swift Package）
  Sources/NotifyBridgeCore/    BLE 帧协议与 JSON 模型
  Sources/NotifyBridge/        菜单栏 App、CoreBluetooth、通知中心
  Sources/ProtocolSelfTest/    无 XCTest 依赖的协议自测
scripts/build-macos.sh         构建 .app
scripts/make_icon.py           生成图标
docs/protocol.md               BLE 协议与安全说明
dist/                          构建产物（.app/.dmg/.zip/.apk）
```

---

## 设计取舍与后续方向

当前版本刻意保持“单机、本地、无账号”：

- 手机只作为 BLE 外设；Mac 主动连接。
- 没有云端中转，因此不能跨网络、不能离线后补发。
- 不读取微信数据库、不注入微信、不申请无障碍权限。
- 不做通知点击跳转回手机（需要额外的协议和 Android 端处理）。

可以继续做：

- Windows/Linux 接收端（WinRT BLE / BlueZ）。
- LE Secure Connections 或应用层 AES-GCM 加密。
- 通知撤销同步（手机清除通知，Mac 同步移除）。
- App 过滤、勿扰时段、快捷回复（Android RemoteInput）。
- 开机自启、多设备记忆。
- 把 Mac 端改为 Xcode 工程并做 Developer ID 签名/公证。

---

## 许可与使用边界

本项目用于个人学习和自用。使用前请确认你对自己设备上的通知内容有处理权，并遵守微信、短信服务商及当地法律法规的要求。不要把它做成未经他人同意读取其通知的工具。
