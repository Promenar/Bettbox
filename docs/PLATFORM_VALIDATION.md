# 共享客户端与平台验收

## 代码与分支

Bettbox 使用 Flutter。页面、Riverpod 状态、Xboard API、邀请分享及收益展示共用 `lib/`。Flutter 支持 Windows、macOS 等原生桌面构建，插件仍须具备对应平台实现，见 [Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)。

项目保持单仓库、共享业务主线。短期功能分支用于隔离开发与评审，平台差异放在 `android/`、`macos/`、`windows/` 及有边界的平台实现中，不维护三套长期分叉的邀请、账户或商店业务。

| 能力 | Android | macOS / Windows | iOS |
| --- | --- | --- | --- |
| 邀请链接、二维码、收益 | 共享 Flutter 实现 | 共享 Flutter 实现 | 共享业务/UI；模拟器应用编译与未登录页面已验证 |
| 跳转型收银 | 嵌入式 WebView，并提供浏览器入口 | 系统浏览器 | 按 PRD 接 Apple IAP，不能沿用桌面收银作为完成方案 |
| 内核运行 | 原生动态库与 VPNService | 独立 core 进程和平台服务 | 独立 Packet Tunnel 与内嵌核心候选，真机待验收 |
| 系统集成 | Android 权限及生命周期 | Keychain/安全存储、托盘、代理、TUN、安装服务 | App Group、签名、隧道权限、后台生命周期 |

## 本机开发环境与分工

本机负责 Android、iOS、macOS 的开发与调试；Windows 原生构建、UI、代理/TUN 和服务调试使用 Windows 环境，现有 GitHub Windows 编译验证保留。具体 Android/iOS 构建与联调入口须在执行前登记到 PDEC；环境安装不代表平台业务已验收。

2026-10-07 本机核对：Apple M5、32GB 内存，Flutter 3.44.9、Xcode 27.0、CocoaPods 1.17.0、Go 1.26.5，Android SDK、项目指定 NDK 28.2.13676358 与 CMake 3.22.1 已安装。Flutter/Dart 尚未加入当前 shell PATH，命令可使用已配置 SDK 或项目工具入口。

Android 的 Nexara_API_31、Nexara_API_35 和 Pixel_7 是共享主机上的多系统版本测试设备，前两个由 Nexara 兼容性验证使用，Pixel_7 的当前镜像为 API 36.1。日常开发共用一个 AVD，兼容性回归才切换版本；不按项目数量新建模拟器，不删除其他项目仍引用的设备。关闭的 AVD 只占磁盘。

iOS 27.0（24A434）ARM64 运行时已通过 Xcode 官方下载入口安装，下载约 8.05GB，运行时文件约占 7.5GiB。iPhone 17 的 simctl bootstatus 验证通过，Flutter 识别为受支持的 iOS 模拟器；当前已安装并启动 Bettbox 候选应用，未登录首页及登录入口可操作。Xcode 自动生成的机型配置共用这份运行时，日常使用一个 iPhone 模拟器即可。Bettbox 已生成 iOS Runner 工程，Packet Tunnel 与宿主桥接正在集成；模拟器环境不能替代项目签名与真机 VPN 验收。

## 已落地的平台差异

`RedirectCashier` 只在 Android 创建 WebView 控制器。桌面使用 `url_launcher` 的 externalApplication；失败有本地化反馈。初始支付地址必须为 HTTPS 且不能包含 userinfo。Android 控制器在普通重绘时复用，地址变更时重新初始化并丢弃旧异步结果。QR 收银分支独立。

macOS 的 DebugProfile 与 Release entitlements 含安全存储插件要求的 `keychain-access-groups` 空数组；Team/App Group 未被硬编码。实际 Xcode 构建确认该 capability 要求开发证书；无团队时只能先做显式关闭 Xcode 签名的编译，不能认定 Keychain 登录持久化已验收。插件具体要求以锁定版本 flutter_secure_storage 10.3.1 的文档为依据，实际持久化仍须同签名标识的原生冷启动验证。

## 邀请业务验证

测试站点为后台 `app_url` 可配置项；客户端从 `guest/comm/config` 读取，不把该测试域名固定在邀请业务代码。公开网页路由 `/#/register?code=` 已验证可以预填邀请码。

`scripts/run_xboard_invite_check.py` 用已有 SSH 身份在指定 Xboard 容器的精确镜像上启动临时验证容器。执行器强制无网络、只读根文件系统、只读继承卷、移除 capabilities、禁止提权、限制 1 CPU / 256 MiB / 64 PID，并只给 `/tmp` 64 MiB 临时写入空间。脚本不输出认证响应、临时密码、邀请码、完整 inspect 或异常消息。

```sh
python3 scripts/run_xboard_invite_check.py \
  --ssh-target USER@TEST_HOST \
  --container XBOARD_CONTAINER \
  --report .test/invite-isolated-result.json
```

`verify_xboard_invite.php` 只读源 SQLite 的 DDL 和数字类型的公开佣金设置，在单进程 `:memory:` 中建立空业务库，并隔离缓存、邮件、队列和插件数据。实际经过 HTTP Kernel 创建邀请码与注册，实际调用 OrderService 算佣金及 `check:commission` 结算。付款完成状态由夹具模拟，不调用支付网关、`paid()`、`open()` 或真实邮件发送。

2026-09-22 验证通过：100 元订单按 10% 规则产生 1000 分佣金，`invite/fetch.stat` 从 `[1,0,1000,10,0]` 变为 `[1,1000,0,10,1000]`，顺序重复执行保持余额和流水不变。原始脱敏结果见 `validation/2026-09-22-invite-isolated.json`。

这不覆盖公网注册提交、邮件收件、下载引导、真实支付、提现或并发结算。正常定时调度已使用 `onOneServer()` 与 `withoutOverlapping(5)` 防止任务重入。`CheckCommission` 单笔查询没有行锁，CommissionLog 没有相应交易唯一约束；直接并发调用命令或调度锁失效时，数据库层幂等仍需独立验证。当前没有正常调度重复入账的实测证据，不能把这一边界描述成已发生的重复返佣。

测试面板只读配置检查确认 `android_download_url`、`windows_download_url`、`macos_download_url` 均为空。客户端下载接口已有这些配置项；网页注册后的安装引导，需要先准备适合分发的安装包，再配置有效地址并验证网页实际入口。GitHub CI 的开发 artifact 不能直接视为匿名用户可用的正式下载地址。

## 原生构建与设备验收

开发执行位置、工具版本、触发和产物见 `.pdec/README.md`。`scripts/validate_desktop.py` 默认只做前置检查，`--execute` 才编译；无开发证书时 macOS 另加 `--unsigned-macos`，其 manifest 记录请求关闭 Xcode 签名及实际签名事实，不能作为可分发安装包。Windows 构建产物只上传为保留 7 天的开发 artifact，不发布正式版本。

设备验收应使用相同候选 SHA：登录/退出与冷启动恢复、邀请码复制与实际扫码、系统浏览器收银跳转、订阅刷新、代理连接、TUN 权限、休眠恢复。Windows x64 和 macOS arm64 的结果不能替代 Windows arm64/macOS Intel 验收。Android WebView 的第三方 Cookie 与导航白名单约束也需单独补齐实机验证。

2026-09-22，macOS arm64 在候选 `9a59d0d56a55b5b8c78b295b56500b462d463634` 上完成编译和 bundle 核对：App 169.3 MB、127 个 bundle 文件纳入哈希清单，源码与锁文件无漂移，`Contents/MacOS/BettboxCore` 与源 core SHA256 相同。签名事实为链接器 ad hoc、无 Team、Info.plist 未绑定且无资源封印；这份编译产物尚未完成开发者签名。证据见 `validation/2026-09-22-macos-arm64.json`。后续 Windows 工具入口修复未改变这份候选的客户端 Dart/Go/macOS 业务源码。

2026-09-22，Windows x64 在候选 `dd2998859b23f6fac9245077ebcd842e1e424d2a` 上完成原生编译、源码/锁文件无漂移检查及开发产物上传，见 [Windows 构建记录](https://github.com/Promenar/Bettbox/actions/runs/35716722203)。82 个 bundle 文件纳入哈希清单，包含 `sqlite3.dll`；App、Mihomo core 和 helper 均已生成，bundle 内 core/helper 与本次源产物 SHA256 一致。证据见 `validation/2026-09-22-windows-x64.json`。短路径构建使用 `S:\s`，7 个 Flutter 平台生成文件通过 `.gitattributes` 固定 LF；源码漂移检查持续启用。此结果不包含 Windows 图形界面、代理/TUN 或服务安装的实机运行验收。

## iOS 工程工作包

用户已有 iPhone，开发者团队尚未准备好。仓库已生成 `ios/` Runner 工程，宿主与 Packet Tunnel 正在集成；共享 `ClashCore()` 已接入 iOS C ABI 与系统 VPN 桥接；完整应用编译和真机 VPN 仍按独立门禁验收。

1. 复用并扩展既有 `ClashHandlerInterface`，保持 Android/桌面实现行为，为 iOS 提供独立的连接、停止、状态、日志和统计实现；不能复用桌面进程启动方式。逐项检查本地插件：tray_manager、window_ext、proxy 属于桌面能力，需要保持平台隔离；flutter_qjs 和 code_forge 已声明 iOS 支持，仍需与主工程一并构建验证。
2. 建立 Runner 与 Packet Tunnel Extension，通过 App Group 交换必要配置；认证值使用可明确授权共享的 Keychain，不能把订阅凭据写入普通共享偏好。
3. 编译适配 iOS 的 Mihomo 原生内核，处理 PacketFlow、路由/DNS、内存上限、宿主与 extension 通信；现有 Go Android JNI 与非 Android空回调不能直接作为 iOS 实现。
4. Apple Developer 团队准备后配置 Bundle ID、App Group、NetworkExtension entitlement 与设备签名，验证真机联网、切网、锁屏、后台、断开/重连与异常退出。
5. 按 PRD 对接 IAP 商品映射及服务端交易校验、入账和返佣；再进行商店构建与分发验收。

前两项可独立准备，隧道签名与真机 VPN 属于后续验收条件。没有可运行的 Packet Tunnel 与签名证据时不标记 iOS 已支持。

## 三端发行目标的当前验收边界

共享网络安全基础候选 `93f82e2` 已推送，106 项 Flutter 全量测试与额外4项实际 IO 重定向测试通过，静态检查通过。Android release 签名与内核缺失门禁已纳入该候选；正式 Android keystore 已按用户授权在本机创建，签名 APK 尚未构建验收。

完整 iOS Mihomo C ABI 已编译为设备与模拟器 arm64 XCFramework，并通过两套 SDK 的 Clang/Swift 模块导入检查。原生包流适配的真实 listener、并发停止、RPC 取消与 DNS 初始化测试通过 `go test -mod=readonly -race -tags with_gvisor ./iosbridge`。静态库回执保留 `vpn_ready:false`，尚未验证系统 PacketTunnel、签名、设备数据流和资源预算。

macOS 当前工作树编译生成169.3MB应用，实际启动及未登录首页、账户、登录页和NoSLA套餐读取正常。构建期间并行源码变化使来源一致性检查拒绝通过，须稳定后重建；这份应用不是已验收发行包。

付呗候选的原始回调表单与金额 token 修复通过117项真实PHP隔离测试，执行容器禁网、只读、64MiB且无业务数据/凭据挂载。此证据不包含官方支付请求、真实付款、完整数据库事务或返佣并发验收。插件保持禁用，事务补丁与快照接线独立审阅和验证后才能决定启用。

原生 Shared 与 PacketTunnel 已通过 iOS Simulator SDK 的真实 Swift 类型检查，发现的 C 指针桥接类型问题已修复。审阅发现的独立停止截止时间、快照完整文件集合/实际复制预算与单在途控制消息均已修复，RunnerTests 7项原生测试已在模拟器实际运行通过，51个原生输入文件来源无漂移；Runner arm64 模拟器完整应用已实际编译通过并安装启动，未登录首页和登录/注册导航另行记录，真机 VPN 未验收。Android 构建曾完成核心生成但失败于 Gradle 插件解析；实际 DNS 100.100.100.100 返回 RPZ NXDOMAIN。用户已授权仅在项目构建中解析官方依赖，任务专用解析与 TLS/Gradle 门禁正在验收，未修改系统 DNS。

服务端事务候选核验发现线上3个来源文件包含既有订单防护和余额抵扣后的佣金基数行为，不能直接应用本地基线补丁；候选按线上来源重基。SQLite 并发执行器仅传输17个明确公开文件，使用128MiB禁网容器和一次性数据库，无生产库或秘密挂载；实际多进程事务、负手续费拒绝、幂等返佣及 outbox 恢复已通过，来源无漂移且资源清理验证通过。真实 Laravel 集成已在精确镜像的禁网隔离容器中通过，来源无漂移且资源清理验证通过。测试经过 HTTP Kernel、真实订单服务、同步队列、返佣命令与持久 outbox；认证、插件发现和支付网络传输为明确夹具，不覆盖生产认证、真实付款或该夹具中的并发。

Android 正式发行密钥已在本机创建，密码位于登录钥匙串，密钥目录0700、文件0600。公开证书 SHA256 为 `6a121d74f9159b27e4b44255db8f85a9cb8d59ae052e93ba7646666d8a044a82`；后续版本必须使用同一身份。正式 APK 的签名、安装及业务全路径仍待构建验收。

正式签名构建接线通过独立审阅，57项构建、契约及签名测试通过；`--release` 使用单独批准的 Android 扩展，计划模式不读凭据，签名密码只进入 APK 构建进程，生成后校验证书锚与单一 signer。测试为受控 mock，不作为实际 APK 实签或安装证据。

完整 iOS 模拟器应用构建使用当前工作树，来源检查通过；Pods 最低系统版本对齐 iOS 15、Runner 与 PacketTunnel 链接 SDK libresolv，模拟器候选仅包含 arm64。模拟器不支持系统 VPN，编译和页面操作不作为真机隧道、商店签名或可分发版本证据。最新共享 Flutter 135 项测试通过，静态检查无问题。

Android 官方依赖使用仅任务的 loopback CONNECT 代理，139项网络、构建、契约及签名集成测试通过；32条转发与6条解析/连接分别有界限流，回执记录代理自产拒绝计数。实际 Java TLS、官方重定向与 Gradle 8.14 下载通过。容量调整后的真实门禁仍失败：213次上游连接、3次排队超时和1次请求头拒绝，不足以认定官方源或网络容量为最终根因。原回执的进程清理验证失败；后续只读检查没有发现该任务持有者，不覆盖原失败记录。

隔离复现脚本 `python3 scripts/check_android_regressions.py` 在候选 `23747c0` 上证明慢请求头使全局门禁失败，以及带空格 Java 路径无法认定归属；当前实现两项通过。请求头超时仅关闭该连接，安全边界拒绝保持全局失败。清理使用内核可执行路径、仅 argc 个参数和实际目录文件描述符校验身份，终止前重新核对 PID 与启动时间；保留原始失败并独立记录清理失败。该证据仅为公开夹具、回环和 mock，不包含真实进程终止、正式 APK 或签名验收。

macOS 发行审阅确认尚需修复：当前 TUN 提权把整个 core 设为 root/setuid，IPC 入口缺少调用者鉴权；监听成功与系统代理操作返回值尚未完整约束连接显示，代理清理没有本应用配置所有权快照。桌面来源冻结已加入构建输入实际字节哈希，包含未跟踪源码并排除秘密文件；19项测试通过，独立审阅确认该来源冻结补丁无新增P1/P2；Windows回退拒绝reparse point并在读取后核对父路径，句柄级竞态防护尚未在Windows验证。正式 Apple 签名路径还需要身份校验与签名前后制品关系，现有 ad hoc 验收不能替代正式签名。

iOS 发行存在用途兼容风险：当前捕获流量交给 Mihomo 后仍允许 DIRECT 回退与逐连接代理，DNS 缺省捕获 `any:53`；这与 Apple TN3120 的 Packet Tunnel 用途限制冲突，不能按当前实现判定发行验收通过。未发现扩展托管外部代理服务器的证据。用户已确认优先交付 Android、macOS，iOS 保留开发版并研究发行方案；未授权收缩节点协议或完整代理功能。macOS 保留现有规则代理功能时，受限 utun fd broker 优先于套用该 Packet Tunnel 路径。依据：[Apple TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)；直接 Developer ID 的 Network Extension 分发形式另见 [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)。


macOS 系统代理事务核心位于 `plugins/proxy/macos/`，实际 Swift 编译与23项隔离测试通过，覆盖串行生命周期、取消、提交/应用差异、外部配置冲突和有证据恢复。测试后端为 fake；SCPreferences、受保护 journal、Flutter channel 与现有 App 接线尚未完成，系统代理实际行为未验收。当前已有应用为 ad hoc 候选且嵌套签名核验失败；本机确认 Apple Development 身份，但未找到 Developer ID Application 身份。

自有短寿命 Java 夹具实际核验 JBR 内核路径、精确 argv 与环境隔离通过，进程自然退出且无信号。清理补充同 UID/PID 候选枚举，发现无目录FD的任务JVM时只阻断成功、不授予信号权限；独立审阅闭合两项P2，初始/最终枚举异常均有回归。

候选 `802d510` 的真实发行尝试通过工具链、Java TLS、官方Gradle文件下载与实际JVM门禁，但在Gradle help阶段因1次白名单外目标拒绝停止，APK未生成、签名凭据未读取。固定事件为214次成功上游连接、queue-expired3、target-outside-allowlist1、header-timeout0；来源与锁文件无漂移。原清理回执false保留；只读定位发现同UID非Java进程的内核路径不可读取，不能解释成仍有任务JVM。候选扫描增加公开ucomm前置筛选，Java候选仍严格核验；真实JBR样本命名与身份通过、无信号，后续只读任务候选count0不追认原清理成功。

QuickJS Android插件移除声明的JCenter/JitPack仓库，依赖版本保持不变，Kotlin1.3.50官方Maven POM可用；被拒绝的原请求确切主机未知，不归因于该声明。修复前静态仓库范围与受保护非Java夹具均失败，修复后139项集成测试通过并独立复审无新P1/P2。未知CONNECT只记录3种固定来源标签，不保存hostname或请求头。Gradle8.14完整发行ZIP的SHA256已与[官方校验和](https://gradle.org/release-checksums/)匹配，Wrapper固定相同校验和；真实依赖配置、APK、实际Gradle/worker命名和退出仍需验收。

Wrapper启动JAR经官方SHA核对确认原本为2.10，不能执行发行ZIP校验和配置；已从完整性匹配的8.14官方ZIP内提取嵌套Wrapper JAR，SHA `7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172` 与官方一致。保留启动脚本，4个Wrapper文件纳入Git/PDEC/来源冻结；旧文件在本机任务目录备份，Gradle运行版本维持8.14。新的ZIP预置仅复用项目内匹配官方SHA的独立副本，检查父目录与实际副本，坏源不回退；不复用Maven或编译缓存。139项工具测试含33项ZIP夹具通过，独立审阅无新P1/P2；真实预置、启动/解压及完整编译仍待验收。失败公开回执为 `validation/2026-10-07-three-platform/android-802d510.json`。

候选 `1f998ae` 真实debug构建确认官方ZIP独立预置与解压成功、Gradle help和实际JVM门禁通过。Go ARM64核心生成与锁定pub get通过，Flutter APK失败在 `:core:configureCMakeDebug`：core库没有继承Flutter的目标架构，尝试配置未生成核心的armeabi-v7a。来源、锁文件未变，任务网络关闭与独立Gradle清理验证通过。实际Gradle daemon和Kotlin compiler的公开ucomm为java，Java入口及任务目录参数匹配；未观测worker主类，不能外推该覆盖。公开回执为 `validation/2026-10-07-three-platform/android-1f998ae.json`。原生模块按Flutter公开target-platform参数设置ABI过滤，未知目标拒绝；静态回归修复前失败、修复后通过，真实修复构建待验收。已有Pixel_7 ARM64模拟器启动完成，当前页大小4096，不能替代16KB设备验收。
