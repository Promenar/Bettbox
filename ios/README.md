# Bettbox iOS 原生桥

最低系统版本为 iOS 15。Runner 使用 Flutter 隐式引擎插件入口，PacketTunnel 是独立 Network Extension 目标，两者分别静态链接 `Vendor/BettboxCore.xcframework`。框架由 `scripts/build_ios_core.py` 的锁定源码构建流程提供，不放入源代码分发。Extension 不依赖 Dart VM、桌面进程或私有 utun 文件描述符。

## 通道契约

MethodChannel 为 `bettbox/ios`，EventChannel 为 `bettbox/ios/events`。Action 与 ActionResult 沿用现有 Dart/Go JSON 模型，JSON 中 `data` 保留现有字符串编码。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `coreAction` | `action`：Action JSON 字符串；`transport`：`auto`、`offline`、`online`；`timeoutMs`：1～30000，默认 10000 | ActionResult JSON 字符串；传输失败返回 FlutterError |
| `publishSnapshot` | `setup`：SetupParams JSON 字符串；`state`：可空 CoreState JSON 字符串；`network`：下述映射；`resources`：`[{path,sourcePath}]` | `{schemaVersion:1,revision,manifestHash}` |
| `startVpn` | `revision` 与 `manifestHash`，来自快照发布结果 | 系统状态映射，`accepted:true` 只表示启动命令交给系统 |
| `stopVpn` | 无 | 系统状态映射，`accepted:true` 只表示停止命令交给系统 |
| `getStatus` | 无 | `{status,connected,transitioning,connectedAt?,revision?}` |
| `sharedPaths` | 无 | `{offlineCoreHome,appGroupID,appGroupAvailable,snapshotRoot?}` |
| `getCapabilities` | 无 | `{schemaVersion,networkExtensionDeclared,appGroupID,appGroupAvailable,requiresDeviceValidation:true,offlineCore:true}` |

状态事件为 `{kind:"vpnStatus",status,connected,transitioning,...}`，从 `NEVPNConnection.status` 与 `NEVPNStatusDidChange` 读取。核心事件为 `{kind:"coreMessage",data:ActionResultJSON}`。`connected` 包括系统 `connected` 和 `reasserting`；两者的精确名称保留在 `status`。未完成系统连接或核心启动时不能将 `accepted` 映射为已连接。

`auto` 在系统隧道已连接时向 `NETunnelProviderSession.sendProviderMessage` 发送版本化控制消息，其它稳定断开状态调用 Runner 进程内离线核心。连接、断开中不回退离线运行。Extension 禁止外部消息调用 `initClash`、`setupConfig`、`startListener`、`stopListener`、`shutdown` 和 `crash`；这些操作由系统隧道生命周期负责。Runner 也禁止桌面 Listener 启停及 crash。一个进程内控制请求和扩展消息均限制同时一个在途操作，忙时返回错误。

模拟器编译分支明确返回 `vpnSupported:false`，读取状态和离线 Action 不访问系统 VPN 偏好；`startVpn` 返回不支持错误。真机分支仍读取真实系统状态，读取失败不能回退成稳定断开。此能力字段同时出现在状态与 `getCapabilities` 中。

## 配置与资源

`network` 使用 camelCase 字段：`mtu`（默认 1480）、`capacity`（默认 256）、`ipv4Address`（默认 `198.18.0.1/30`）、`ipv6Address`（默认空）、`dnsServers`（默认 `198.18.0.2`）、`includeRoutes`、`excludeRoutes`、`includeRoutes6`、`excludeRoutes6`。地址与路由为 CIDR；DNS 必须为数字 IP。包含路由为空时采用对应地址族默认路由。IPv6 地址必须与 `setup.config.ipv6` 一致。队列预算不超过 8 MiB。核心 DNS 劫持使用 `any:53`，系统 DNS、路由与地址由 Network Extension 设置。

快照位于 App Group 的 `BettboxSnapshots/<revision>/`，先写同目录临时子目录，再原子移动发布。`snapshot.json` 的 SHA-256 随 revision 交给系统 providerConfiguration；扩展在初始化前验证清单版本、摘要、资源大小及摘要。资源来自 Runner 私有容器，最多 512 个、单文件 64 MiB、总计 256 MiB；复制按实际字节数限制预算。源目录及运行副本的完整文件集合都须匹配资源清单，拒绝额外文件和符号链接。相对目标路径禁止绝对路径、空段、`.`、`..` 和符号链接逃逸。provider 绝对缓存路径必须匹配显式资源输入后重写为核心目录内相对路径。调用方须列入实际依赖的 GeoIP、GeoSite、规则及 provider 缓存文件；缺失资源不会被声明为可用。

共享文件与目录使用 `completeUntilFirstUserAuthentication` 文件保护，以允许首次解锁后后台隧道运行。App Group 偏好不存放登录 token；登录凭据由现有安全存储负责。快照白名单只接收核心 SetupParams/CoreState，并可能包含代理密码、运行所需订阅 URL 等敏感配置，不能输出正文到日志。清单摘要提供完整性绑定，不是来自独立信任方的签名。源应用和扩展共同持有 App Group 写入权限。核心使用独立受保护的运行副本，provider 缓存更新不会修改待校验的资源；正常停止且 shutdown 成功后删除该副本，超时或进程被系统终止时可能留下副本。快照按 revision 保留，应用层需要在确认已断开及未引用后制定旧快照清理策略。

## 生命周期与数据通路

Extension 按 `initClash → setupConfig → setState（可选）→ setTunnelNetworkSettings → bettbox_core_start` 执行，只有真实核心 running 后完成系统启动回调和读取 packetFlow。总启动等待上限 45 秒，C 控制请求各自有界；超时触发失败并请求核心清理，不能证明底层操作已同步终止。

输入使用公开 `readPackets`，核验包的 IPv4/IPv6 版本与 `AF_INET`/`AF_INET6` 一致后复制进有界 Go adapter；队列满时丢包。输出定时 poll，每轮最多 64 包，按地址族调用公开 `writePackets`，不持有 C 字符串。所有 C 字符串通过 `bettbox_core_free` 释放。停止取消输出定时器、更新生命周期和包代次；公开 API 没有取消已提交 `readPackets` 的接口，其迟到回调由代次忽略。停止回调具有独立于控制队列的 15 秒截止时间，超时归还系统回调但清理继续排队；不声称 Go 工作已及时终止。

## 签名与验收

声明的标识为 Runner `com.appshub.bettbox`、Extension `com.appshub.bettbox.PacketTunnel`、App Group `group.com.appshub.bettbox`。团队设置保留为空。发布者必须在自己的 Apple 团队核验两个 App ID、App Group 和 Network Extension 权限，配置对应签名；本工程声明不代表团队能力已经开通。

主控执行位置和候选版本确认后，可执行以下验收；这些命令不是本实现已经运行的证据：

```sh
flutter build ios --simulator --debug
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=iOS Simulator,name=<实际设备名称>' test CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

模拟器验收包括 Runner 插件注册、离线 Action、CIDR/队列预算/路径校验测试、双 SDK 编译与扩展嵌入。真机使用具有上述权限的签名安装后验证系统授权、全隧道 DNS、IPv4/IPv6、核心事件与在线 RPC、睡眠唤醒、锁屏、应用重开、连接时取消、重复停止、配置缺失/摘要错误/启动超时与流量压力。模拟器编译成功不等同于真机 VPN 可用。Provider 消息的大型响应受系统 IPC 实际限制，当前原生接收上限为 4 MiB；全量 provider 数据规模需真机验收。

官方接口来源：[NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)、[NEPacketTunnelFlow.writePackets](https://developer.apple.com/documentation/networkextension/nepackettunnelflow/writepackets(_:withprotocols:))、[NETunnelProviderManager.loadAllFromPreferences](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager/loadallfrompreferences(completionhandler:))。

本机模拟器制品只包含 arm64 内核；Runner 与扩展排除模拟器 x86_64 架构，系统解析依赖由 SDK libresolv 链接。宿主最低 iOS 15，CocoaPods 中更低的目标统一提升到15，更高目标保留。
