# 共享客户端与平台验收

2026-10-08 当前Android正式候选为f881880，同源构建/正式验签/安装回读通过；DIRECT模式本机HTTP代理200与Chrome HTTPS通过，两轮停止均确认tun0和7890消失，设置已恢复规则模式。上游节点协议代理、邀请网页注册归属和真实付款未验收。macOS schema4核心84项、Session恢复门禁24项与严格回执5项通过并完成独立复审；宿主同份核心SDK编译与夹具检查通过，当前Application接线回归与Flutter全量219项通过，静态分析无问题；完整macOS Release Runner构建成功（171.4MB），源码和锁文件前后相同。构建为unsigned模式，系统授权、真实SC写入、正常界面启停/退出及上游代理流量未验收，不能作为可用发行版。iOS按用户裁定保留开发版与发行方案研究，当前交付优先Android/macOS。详见各独立公开回执。

普通宿主只获取非阻塞SC锁时真实返回permissionDenied，签名比较确认系统偏好未变；空受保护journal恢复已改为免SC锁，64项核心回归及独立复核通过。非空journal仍需要原权限与CAS验证。Host追加迟到SC start未终结门禁，定向SDK编译和夹具通过；原始scope4/Host回执保留各自版本，当前证据见 `validation/2026-10-07-three-platform/macos-empty-journal-validation.json` 与 `macos-host-late-sc-validation.json`。原生授权引用与SC session生命周期已实施，84项核心测试、宿主SDK编译和完整unsigned Runner构建通过并完成独立审阅。取消/过期请求/资源释放失败不发布成功，资源关闭同步先于completion；实际OS认证、SC写入及正常界面运行另验。macOS旧root/setuid路径已删除，当前TUN入口明确拒绝并提示使用系统代理。

2026-10-08 Android VPN 路径实测：23 个订阅节点加载，首页显示自动及8个地域；系统授权后建立 `tun0`。直连模式核心代理 HTTPS 200、浏览器显示 trace；默认代理及香港全局路径失败，停止后同URL恢复，`tun0`撤销、应用回到就绪，任务ADB转发已移除。23个TCP端点可连接、12个AnyTLS TLS证书验证通过，但这些不证明协议认证或节点转发。订阅密码均不等于开发用户UUID；辅助Mihomo仅VMess，不作为相同协议对照。代理节点流量仍未通过，见 `validation/2026-10-07-three-platform/android-vpn-path-validation.json`。

2026-10-08 正式 Android 候选 `e7b5a87` 已构建、验签并覆盖安装，回读 APK SHA256 一致；账户字段原生输入类型 `0x800b1` 已关闭纠错和建议。模拟器中文输入法改写 ADB 按键，切换已有 Alphabet 后公开 ASCII 与真实邮箱完整匹配；真实登录、账号身份、邀请入口及冷启动恢复通过，首页显示 64 MB 配额，输入法设置已恢复。8 项通道回归和完整 Flutter 192 项通过。VPN 真实流量、节点实际呈现、邀请注册闭环和支付尚未验收，未公开发布。见 `validation/2026-10-07-three-platform/android-e7b5a87-apk-validation.json`。

2026-10-08 Android 正式候选真实业务验收：独立开发账户的真实登录、账户、订阅与节点接口均 HTTP 200，订阅未过期，返回 23 个节点。客户端界面登录、冷启动安全存储及 VPN 流量尚未验收；后台创建账户不是网页邮件注册或邀请绑定证据。见 `validation/2026-10-07-three-platform/android-live-account-validation.json` 与 `.agents/plans/2026-10-08-android-live-account.md`。

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

候选 `b6d7a58` 真实debug构建成功编译APK，但最终ABI验收拒绝包内ARM32/x64插件库。Mihomo、JNI与Flutter核心均为ARM64；12个ARM64库逐一通过实际ELF及16KB LOAD对齐检查。来源/锁文件未变、任务网络关闭与Gradle退出验证通过。Flutter应用插件的默认打包过滤为全部支持ABI，App defaultConfig按显式target-platform覆盖过滤；未指定目标保留默认，完整修复构建待验收。公开回执 `validation/2026-10-07-three-platform/android-b6d7a58.json`，不得作为可用APK发行证明。

候选 `748133a` 真实APK通过ARM64范围、全部原生ELF 16KB与zipalign检查，但精确核心SHA拒绝。生成/复制/merged核心字节一致，core库剥离/App剥离/APK为相同转换产物；真实官方NDK llvm-strip --strip-unneeded可精确复现APK核心SHA，排除缓存旧核心。原始核心无debug段和symtab；库与应用仅对libclash.so设置keepDebugSymbols，保持原始字节与精确SHA验收，不放宽校验。12项契约静态回归通过，完整142项工具测试及修复真实构建独立验证。公开回执 `validation/2026-10-07-three-platform/android-748133a.json`；源码/锁文件未变、退出清理通过。

候选 `9d48a29` 调试 APK 完整构建及精确核心 SHA、ARM64/16KB、来源/锁文件与任务清理通过，实际安装到4096页Pixel_7。邀请真实生成、公开注册网页自动预填并锁定邀请码、商店套餐/周期选择通过；未提交新注册或付款。实际启动 VPN 导致 UnsatisfiedLinkError：JNI 的 DT_NEEDED 包含构建绝对路径，产物检查成功不代表设备可用。CMake 对无 SONAME 核心声明 IMPORTED_NO_SONAME，新增动态依赖 basename 与动态段唯一文件映射门禁；旧 APK 被新门禁实际拒绝。正式构建在安全注入前拒绝系统钥匙串0644，未生成发行APK；系统钥匙串权限检查已修复，项目私钥/回执600、证书锚与 ACL 保持。安全注入预检仅输出ready=true，未记录密码。149项工具回归与独立复核通过，修复真实构建及设备启停仍待验收。macOS专用入口请求状态机22个测试函数已独立静态复核，未集成或执行；owned-child匿名管道为可信IPC候选，尚未接线。

### 2026-10-08 Android 启停与 macOS HTTP 实测

Android `ea2aa0a` 完整 debug 构建通过，APK SHA `7e6c4454cc8d16b03392409377e32532b1ba510d2bb4b9d10be9276227b390cf`；JNI 依赖为 basename `libclash.so`，原动态链接启动崩溃未出现。Pixel_7 实际启动后应用存活，VPNService 为前台；停止后服务退出、计时清除。设备页大小4096；系统 VPN dump 中 CONNECTED 可能是事件历史，未证明当前系统 VPN 或真实出口。账号订阅过期，实际节点流量与 Android 失败路径另验。公开回执为 `docs/validation/2026-10-07-three-platform/android-ea2aa0a-debug.json`。

macOS 专用 HTTP 包在 Go1.26.5 Darwin/arm64、只读依赖锁、GOPROXY/GOSUMDB=off、CGO1 下实际执行 -race -count=1，通过23个测试函数；含17MiB流式上传/下载、CONNECT/Upgrade、pipeline/EOF/停止未完成及默认认证响应和InUser归属。公开回执为 `docs/validation/2026-10-07-three-platform/macos-blind-http-race.json`。仅任务loopback/pipe fixture，无公网/系统代理设置；宿主接线、真实服务出口、匿名管道身份、SC事务恢复与发行签名均未由此验证。

macOS owned-child Go入口实际CGO0普通包测试21函数通过，无race证据；生成真实生产入口fixture产物SHA `f63ff6e25187cee38ac85d3430a1545408a9698aba232a6e8e06695257098f86`。`scripts/check_macos_owned_process.py` 五种真实child场景通过，正常首帧/EOF、错误首帧、错误代次、预填65536字节stdout和stderr均自然退出，未强制终止；无有效业务动作、不保留原始标准流、不修改系统代理。满stderr场景仅证明当前初始化/握手/退出，不是活跃业务日志背压验收；宿主身份桥接、初始化exec FD继承与Dart/SC接线另验。公开回执 `docs/validation/2026-10-07-three-platform/macos-owned-pipe.json`。

2026-10-08 状态快照实际先失败后通过：原等价包装器复现畸形JSON部分提交、浅副本别名与并发race；同步深拷贝修复后4项state -race通过。setState action错误字符串合同也先失败再修复，22项共享Go CGO0普通测试通过。公开回执 `docs/validation/2026-10-07-three-platform/client-state-snapshot.json`。Android/iOS Go调用改为快照，原生编译未由这些命令覆盖；Android quickStart/void setState和TUN/JNI失败状态另验。

Android 快速配置前置：旧调用顺序的等价薄包装器在初始化失败与状态失败场景实际失败，修复后生产 helper 的四个子场景经 CGO1 race 通过。独立审阅确认实际 adapter 唯一发送调用点；Android 原生编译和真实投递尚未覆盖该变更。

Android 启停基础：实际 `androidstartup` 包含15个新增资源/回调测试方法及快速配置四个子场景，CGO1 race通过。已审阅的构造清理候选还有2个纯 helper测试通过；该候选未接入真实Android构造器，文本检查未计入行为验收。已排除重复关闭独占Linux FD的修复方案；关闭错误不等于描述符仍存在。Go/JNI/Service/coordinator需整包集成后再做Android编译、引用/FD故障注入、许可拒绝和流量验证。

2026-10-08 macOS 最终 core 身份：真实系统 codesign 正常替换 inode 的动作先被旧检查实际拒绝；修正签名与验签时序后，公开 fixture 独立验签、最终 SHA/CDHash 清单绑定通过，输入二进制未变。34项 Python 回归及3项 Dart setup测试通过；当前完整App/DMG、Keychain、宿主/guest身份和系统代理尚未由此验收。公开回执 `validation/2026-10-07-three-platform/macos-core-final-identity.json`。

Android 协调候选的15个场景已使用离线 Kotlin 2.1.0 缓存编译并在JVM实际运行通过，覆盖许可/绑定撤销、已进入JNI所有权、迟到成功清理、停止失败保留、原FD关闭不确定、bootstrap/restart和旧服务身份。夹具使用编译器POM依赖的coroutines 1.6.4，未核对App最终解析版本；候选尚未接入Android实际后台服务，smart行为未实现。公开回执 `validation/2026-10-07-three-platform/android-coordinator-jvm.json`。

Android 联合候选已补 smart、权限请求归属和 Service lease，尚未接入实际客户端。旧 Doze 回调在同一 Service 被新 lease 复用时影响新连接的问题，经生产 JVM helper 修复前失败、修复后通过；23 个协调场景和权限/stamp夹具使用离线 Kotlin 2.1.0 编译运行通过。20 个 Go helper/静态接线测试经 CGO1 race通过，其中1项仅检查源码接线；编译器夹具 coroutines 1.6.4 不代表App最终解析版本。该回执所验JNI版本在线程附着失败时会abort，不能宣称其所有失败均返回false；当前checked-release处理见下文。Dart配置排空、真实AndroidBackend/JNI/系统VPN及节点流量另验。公开回执 `validation/2026-10-07-three-platform/android-backend-helper-validation.json`。

macOS native身份候选使用当前SDK编译通过，9项fake生命周期测试及强制断言失败检测通过。执行器22项mock与真实owned进程组超时清理探针通过；真实签名宿主/core候选在launch准入失败，并保留cleanup_failed，未发送HELLO。独立固定sleep探针实际确认Foundation Process为child建立独立进程组且该探针child自然exit0；不能用宿主组watchdog证明覆盖core。宿主/core身份与匿名管道验收须在明确child创建/回收合同后执行。公开回执 `validation/2026-10-07-three-platform/macos-native-launch-validation.json`。

macOS 回收兼容性：本机 Dart 3.12.2（revision `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`）官方源码确认退出线程使用 `wait()`，可能回收非Dart登记的child。固定native true与Dart sleep1的真实夹具复现 WNOWAIT ECHILD，两个短时进程退出且Dart登记进程exit0；“不把Core PID交给Dart”不能保证native唯一reaper。POSIX spawn桥经当前SDK clang严格compile-only通过，无spawn；在关闭此生产兼容问题前，纯Swift身份fixture不代表Flutter宿主验收。公开回执 `validation/2026-10-07-three-platform/dart-native-reaper-validation.json`，官方固定源链接见回执。

Android 配置协调候选已通过30个实际JVM场景（23个生命周期场景加7个配置场景），包括配置操作与启停串行、取消后真实配置版本保留但不启动、Entered失败粘性恢复、APPLY_ONLY独立权限和options复制。证据来自生产helper与fake backend，未验证Android服务、Go/JNI、监听器/provider实际完成；公开回执 `validation/2026-10-07-three-platform/android-config-coordinator-validation.json`。

TCP/UDP隧道目标预检：生产构造器回归在修复前两个无效目标子用例失败，修复后 `go test -mod=readonly -race -count=1 -timeout=60s github.com/metacubex/mihomo/listener/tunnel` 通过。验证无效目标零绑定、合法目标绑定一次并保留错误；不直接测量真实FD泄漏。公开回执 `validation/2026-10-07-three-platform/tunnel-constructor-validation.json`。

macOS无Dart辅助进程最小隔离：Dart持有固定C helper，同时有登记的sleep1；helper通过冻结spawn桥创建固定true，250ms后两次WNOWAIT保留child，指定waitpid真实退出0，helper及Dart登记进程均退出0。仅证明该短时父属与回收隔离，不包含Swift supervisor、签名/SDK身份、业务relay或SC。公开回执 `validation/2026-10-07-three-platform/dart-supervisor-reaper-validation.json`。

实际Go集成验收：专用owned入口与既有main包回归在CGO0、with_gvisor下通过；候选36项含14个专用入口场景。两个配置失效绕过序列旧helper实际失败，修复后通过；HTTP现有23项加2项实际Endpoint/accept故障验证经race通过。Checked关闭旧Stop遗漏inbound已实际复现，5项生产API包含真实HTTP/TCP/UDP socket关闭，经当前工作树race通过。回执 `validation/2026-10-07-three-platform/owned-listener-close-validation.json` 绑定格式化后实际13源；不是Dart/JNI/SC或平台流量验收。

macOS supervisor原生模块已纳入 `macos/CoreSupervisor`，当前SDK真实编译、23项identity fake、owner fake及公开true/sleep子进程回收通过。两项P2（后续SDK期间Core变化、kernel读取跨启动截止）均真实红测试失败后修复并经独立回审，4项验证器Python测试通过。公开回执 `validation/2026-10-07-three-platform/macos-supervisor-native-validation.json` 绑定当前实际12源；真实签名guest、生产身份发行器、非阻塞relay、Dart/SC与App接线尚未由此验证。

真实签名SDK链矩阵通过：公开独立App中的host/helper/Core两角色context、bind和recheck成功；错误定位值及已退出guest拒绝，manifest篡改、Core签名移除、helper错误ID三负例固定exit70。正常链helper精确WNOWAIT/reap后exit0，执行器记录身份的资源清理未报未解决错误，执行后无匹配fixture进程。公开回执 `validation/2026-10-07-three-platform/macos-supervisor-signed-sdk-validation.json` 区分签名基线和执行产物；实际Identity源码SHA与项目一致。Core仅为公开等EOF程序，不是Mihomo业务；没有Dart/SC/relay/DeveloperID公证验收。

2026-10-08 supervisor接线模块：actual生产helper及固定产物发行器完成SDK编译，32项原生步骤通过；host提交后期限与整链出生缺口已建立实际红例并修复，最终host定向回归通过。出生负例通过转发实际authority并在SDK结束后无条件改生，红/绿均发生变化。relay缓存取消和HUP前残留输入曾实际返回0，修复后固定失败31；paused-HUP的旧实现公开场景未稳定复现，源码审阅及修复后运行证明已采用明确EOF与缓存保护，不能把它写成实际红例。12项Python工具测试、17项Dart Session及155项Flutter全量测试、静态分析通过。

实际host六ABI、production helper/owner/relay与公开framed Core的签名矩阵通过，SDK27.0；正常case确认握手、credit/result、exit0和native出生消失，清单篡改及helper错误ID拒绝exit70，检查时无匹配夹具进程。公开回执 `validation/2026-10-07-three-platform/macos-supervisor-integration-validation.json` 保存源SHA与执行界限。该回执未覆盖Runner工程、ClashService应用路由、真实Go/Mihomo、SC或完整发行包；iOS按用户选择保留开发版及发行研究，Android/macOS优先交付。

2026-10-08 Runner与真实Go专项：Host/Identity六源、Identity桥接头及窗口通道持有已纳入实际Runner；真实Go Core使用冻结SHA与生产helper/native host完成握手、getIsInit、credit/result和退出，exit0且native确认出生消失，检查时无该夹具残留。公开Core正常/篡改/错误ID矩阵通过，9项Python输出与Core准入测试通过。完整Flutter会话、helper/清单封装、系统代理及有效账户流量另验。证据为 `validation/2026-10-07-three-platform/macos-runner-real-go-validation.json`。

Runner完整Release构建通过，宿主签名关闭，源码与依赖锁均未漂移；Core签名与bundle清单一致。首轮编译成功但因构建中清理空白导致源码漂移被拒绝，冻结后重建通过。宿主未签名且未封装helper，不作为可用发行包或运行身份链证据。

2026-10-08 helper封装：固定arm64生产helper及canonical清单通过SDK编译/签名，源快照前后相等；Xcode复制后源/bundle两个产物及身份核对通过。完整Release构建源码及锁未漂移；独立候选完整开发签名通过，10个framework与最终宿主嵌套严格验签通过，Core/helper签后字节未改变。40项macOS Python、23项桌面Python、156项Flutter和静态分析通过。seal成功清单链接写入经实际红例复现，修后完整流程9测试及独立回审通过。候选仅ad hoc，不是DeveloperID/公证发行；尚未运行完整Flutter新会话或SC，不能称为可用发行版本。共享setup限制已验证arm64，其他架构须独立验收。回执：`validation/2026-10-07-three-platform/macos-helper-bundle-validation.json`。

真实Flutter探针入口为 `integration_test/macos_supervisor_probe.dart`，通过生产MethodChannel、Session、helper与固定真实Go Core连续完成两代getIsInit。每代16个公开true子进程分别确认exit和双管道EOF；Session停止确认helper exit0、控制EOF与native出生消失，最终宿主exit0。未确认所有者保留且禁止新代次。驱动明确冻结两个探针输入摘要，独立签名候选只用于探针，正常App按完整文件摘要恢复。50项macOS工具测试、158项Flutter测试与静态分析通过；回执为 `docs/validation/2026-10-07-three-platform/macos-flutter-supervisor-validation.json`。

探针ad hoc签名不携带entitlements，不加载账户、配置或系统代理。正常候选保留Release钥匙串权利；实际系统AMFI曾拒绝带受限entitlements的ad hoc探针，即使严格验签通过。ClashService、SC事务、Keychain冷启动及有效订阅流量尚待联合验收；完整可分发应用尚未交付。

macOS应用接线：ClashService通过生产Application/Session/RPC管理启动、重启、请求、就绪和停止，不创建旧控制socket、不直接启动/终止Core、不进行legacy fallback。含就绪等待最多8个请求，重启排队最多8个；RPC结果序列化预算16MiB，单事件1MiB，异步事件批次最多32个且序列化预算16MiB。事件监听器的Future返回值可观察，失败与全部结束分别跟踪，未知任务不能被Coregone清洗。回执 `docs/validation/2026-10-07-three-platform/macos-application-supervisor-validation.json` 确认真实Flutter两代Application/RPC、32个公开child及native停止，181项Flutter测试与静态分析通过；正常main的登录、SC与有效流量另验。

macOS预检恢复：`confirmPreflightStopped(generation)` 只在原生SDK worker结束、同代ticket撤销且停止、reservation未发行且无helper/Core记录时确认。Session没有launch/exit/worker才消费证据，超时保留worker；已发行reservation与未知状态拒绝清理。当前184项Flutter测试和静态分析、host生产typecheck及确定性交错测试通过；实际Application/Session重试的native/transport为fixture，未重新执行签名Flutter探针或正常main。回执 `docs/validation/2026-10-07-three-platform/macos-preflight-recovery-validation.json`。

macOS系统代理后端候选：SystemConfiguration使用当前NetworkSet、非等待配置锁、独立Commit/Apply和运行Proxies双读；白名单合并保留认证及未知键，PAC/WPAD仅写启用位，HTTP-only事务不写SOCKS并拒绝其启用/未知运行状态。当前34项Swift测试及真实SDK只读数量验收通过，未改变配置签名；仅有动态Proxies字典不证明网络或代理流量。真实服务认证均unknown，start被拒绝；生产journal候选见下文；native消费授权、Flutter注册与实际写入/恢复尚未实现验收。HTTP-only journal为schema3，旧2拒绝自动恢复。回执 `docs/validation/2026-10-07-three-platform/macos-sc-backend-validation.json`。

macOS受保护journal候选：native固定路径、0700目录/0600单链接文件、ACL与路径inode校验、生命周期flock及稳定安装owner ID；schema3采用有界canonical JSON。临时文件先fsync/F_FULLFSYNC再原子发布，目录同步失败保留未知状态并拒绝重用backend。新建或重新打开的完整目录链同步自身和父目录后才发布owner ID。46项Swift测试覆盖真实文件与跨进程锁、损坏拒绝和fake配置恢复；未接入正常App，也不声称抵抗同UID或root篡改。回执 `docs/validation/2026-10-07-three-platform/macos-protected-journal-validation.json`。

Android正式arm64 APK实际构建尝试：官方Java TLS、Gradle help、Go核心与锁定pub依赖通过，APK构建阶段因任务代理拒绝越出批准范围的请求失败；1次outside-other事件尚不能区分未知目标和非CONNECT请求。任务进程退出、网络租约停止、源码和锁无漂移已确认。没有正式APK验签结果，禁止视为发行通过。回执 `validation/2026-10-07-three-platform/android-release-build-attempt.json`。

正式APK拒绝定位已由固定类别证实：maven.google.com为唯一越界目标类别，非CONNECT及未知域名类别为0。Google官方确认其为Maven仓库HTTPS别名，项目任务代理接入后94项回归通过；真实正式APK未由这些测试证明。回执 `validation/2026-10-07-three-platform/android-google-maven-rejection.json`。

正式Android arm64候选：源码ebc7d3c，APK SHA77a1cea24278a4756be5a0c6eb377aa2d4abf70e035880d6bb4ce9a5c9dcd105，单一正式证书与本机身份锚一致。Go核心/头、包内核心、全native ELF及16KiB zipalign通过；源码与依赖锁无漂移，任务代理及构建进程清理确认。候选保存在 `build/releases/android/Bettbox-arm64-ebc7d3c.apk`。Pixel_7 API36安装成功，回读APK摘要一致，首页/登录页真实显示，观察日志致命/JNI/native崩溃标记0；实际页大小4096，未做真实16KiB设备测试。未登录、未验证有效订阅/VPN/邀请注册/支付，release_verified保持false。回执 `validation/2026-10-07-three-platform/android-formal-apk-validation.json`。


### 2026-10-08 同源核心协议探测

受限工具 `core/cmd/nodeprobe` 使用当前 Mihomo 依赖，最多探测两条 AnyTLS 与两条 Hysteria2，仅请求固定 Cloudflare HTTPS trace；不监听、不修改路由或服务配置。规范字段白名单拒绝大小写/下划线别名、嵌套链路及证书绕过，日志静默，原始订阅只由本机执行器传入 stdin。7项Go测试覆盖真实TLS拒绝、固定目标和请求期限；字段别名绕过已用失败测试复现。执行器3项回归覆盖启动前序列化失败、真实子进程超时及非超时异常回收；旧控制流在相同夹具中出现2项失败。两轮独立只读审阅的P1/P2已关闭。

真实执行3.87秒、exit0并确认退出，抽样两条AnyTLS均为transport类失败，两条Hysteria2均为authentication类失败。该分类不包含原始错误，也不证明密码或额度原因；四条共同失败使上游授权、订阅转换与协议配置成为下一步核验路径，Android原生失败处理仍需独立复现。回执 `validation/2026-10-07-three-platform/node-protocol-probe.json` 保存源码、依赖与二进制摘要。此项不证明全部节点、Android JNI/TUN、Mac物理直连或发行验收通过。


### 2026-10-08 上游订阅与原生所有权

三个CloudBridge上游缓存均有用量快照且显示过期、未耗尽；分别用客户端和同步器声明的User-Agent只读获取当前订阅，HTTP均为500/500/403，无用量头或可解析节点。实时有效期未知，无法比较认证字段；不能将HTTP失败归因具体密码或额度。已请用户在后台核验有效订阅，未付款、续费或改变同步配置。回执 `validation/2026-10-07-three-platform/upstream-subscription-status.json`。

生产Android启动的4个实际函数体在公开依赖替身中运行，3项失败回归确认监听器失败仍成功/计时、未配置fd0仍计时及配置nil的正FD重入锁。此项只覆盖控制流，未编译JNI或建立真实TUN，生产接线修复待验；回执 `validation/2026-10-07-three-platform/android-tun-control-flow-red.json`。


`sing_tun.NewWithNativeFDOwnership` 新入口保留原配置与Stack，在NativeTun采纳且登记后同步通知；必须提供采纳回调。构造失败关闭成功则清空，关闭失败则保留部分Listener及首次错误；旧入口的清理行为保持兼容。8项Go测试通过，首次关闭错误丢失与nil回调预检均有实际红/绿回归，并完成未施工者独立复审。测试使用真实Listener.Close和替身Stack；有效NativeTun构造、采纳后的失败、三种栈运行及Android JNI尚未验收，不能称Android修复已完成。回执 `validation/2026-10-07-three-platform/native-fd-ownership-contract.json`。

Android 原生启停接线：Go State/CallbackGate/FDLease、Kotlin 显式领取租约及 JNI Boolean 已接入；输入关闭失败阻断新启动，protect 失败传回 socket 创建方。实际 ARM64 Go 核心及生产 JNI 编译链接通过，纯 Go race 与 Kotlin 租约6例通过，独立静态审阅未发现新增 P1/P2。完整 Service 代际保护、有效 NativeTun 构造和设备启动/停止行为尚待验收，不能将该编译产物作为可用发行版。回执为 `docs/validation/2026-10-07-three-platform/android-tun-abi-validation.json`。

Android 生命周期候选接入完整工作门禁、独立绑定/启动意图及主进程停止锁恢复；旧通知无法修改新代共享状态。两个生产gate/controller协程夹具入口通过，原4项独立审阅发现静态闭合；JNI helper/OnLoad九项故障夹具通过。完整工程及设备行为待验，回执分别为 `android-vpn-lifecycle-validation.json`、`android-jni-failure-validation.json`（位于 `docs/validation/2026-10-07-three-platform/`）。


### 2026-10-08 macOS Apple Development候选

`build/macos-local-candidate/Bettbox.app` 已用现有唯一Apple Development身份完成完整bundle签名；10个框架及最终宿主严格验签通过，Core/helper的既有ad hoc身份与字节保持不变。封装工具20项测试通过，证书Team来自所选指纹对应叶证书OU，未读取私钥或输出原始身份。旧候选保留于 `build/macos-local-candidate-before-c9b0355`。回执 `validation/2026-10-07-three-platform/macos-development-signing-validation.json` 记录源摘要和构建来源。

该产物是本机开发候选，未公证。实际CUA启动被系统拒绝，本地错误分类为缺少matching profile/invalid profile；候选未嵌入profile，两个标准安装目录计数均为0。严格验签成功不能证明系统启动准入。真实App保留DP Keychain与Release权利，未降低安全存储要求；需要Xcode团队/profile及其授权链适配，再验Keychain冷启动、系统代理写入恢复和有效上游流量。封装器对完整候选任何非空权利配置在复制/签名前拒绝，签后实际权利必须匹配预检快照；24项公开回归通过。回执 `validation/2026-10-07-three-platform/macos-profile-admission-validation.json`。Android、macOS优先交付；iOS保留开发版并研究发行方案。


### 2026-10-08 生产监听停止回执

Go handleStopListener及stopListener action使用既有StopListenerChecked，在真实登记对象Close均确认时才返回true；isRunning=false仅停止新监听更新准入。handler/action共8个公开替身场景在修复前均失败，修复后通过，core包CGO0/with_gvisor回归通过。回执 `validation/2026-10-07-three-platform/core-listener-stop-action-validation.json` 保存实际源码与日志摘要。夹具未创建socket/TUN或写系统代理，不证明全部连接drain、provider/controller或Android Service结束。既有Android APK与macOS签名候选未包含此后源修改，须按最终集成版本重建验收。


### 2026-10-08 配置准备层

生产setup的7个早失败场景真实red后修复；13个场景（包含数值及深复制）与core包回归通过。NDK28/API26实际Android ARM64 Go c-shared及生产JNI编译链接通过，独立产物位于 `.test/android-config-prepare-abi`，旧产物保留。回执 `validation/2026-10-07-three-platform/core-config-prepare-validation.json` 保存代码、日志及产物摘要。未安装该产物或验证成功ApplyConfig/真实JVM，不代表完整owner、设备和发行验收。解析器完整副作用回滚没有证明。

Android同步配置中间层：Go生产入口以runLock执行epoch/revision CAS、STAGED初始状态、ENTERED准备/提交及同次options深副本；回执严格区分staged/applied/rejected/unknown，未知保留责任并粘滞阻断。JNI同步桥及Kotlin严格十字段codec已实现，但未接入唯一Native owner。Core全包、state race、实际Kotlin JVM、NDK28/API26 ARM64 Go/JNI编译及17项JNI函数表ASAN验证通过；真实Android JVM/CheckJNI、带版本TUN准入、HTTP/FFI旁路收敛、epoch换代、完整App及业务验收另验。回执 `docs/validation/2026-10-07-three-platform/android-owned-config-validation.json`。

Android生产启动报告：`State.StartWithInputCleanupReport` 在同一状态锁内执行旧资源收口、新资源构造、输入清理和最终状态捕获。输入失败先固化首码，资源Close失败保留resource/lease及已启动runtime；release panic只保留其指针责任，不伪造JNI释放确认。Shutdown先关闭回调准入并等待所有pin，再仅尝试一次释放；listener/release panic转为稳定错误，重复Close保持失败。8项初始报告及6项混合故障在修复前失败；最终定向7项、完整startup race、core回归和Android ARM64 Go/JNI编译链接通过。尚未接带版本TUN入口或重建APK；回执 `validation/2026-10-07-three-platform/android-start-report-validation.json`。

用户所见黑色窗口经当前进程路径与CUA截图确认来自 `build/macos-flutter-supervisor/Bettbox.app`。探针入口 `integration_test/macos_supervisor_probe.dart` 使用 `SizedBox.shrink`，没有客户端业务页面；空窗口不计入完整应用UI或发行验收。

Android注册JNI释放回调使用固定int状态：0未Delete、1删除调用和任务线程finish确认、2后置或既有线程责任未知；非空对象仅1接受，Go nil callback为无释放义务短路。异常清理不打印原文；仅EDETACHED附着，空env安全拒绝，Detach失败以atomic sticky保存，Protect/Resolve不继续调用Java或接受线程收尾未知。当前17个生产函数表ASAN场景、既有9个JNI故障和17个配置桥场景、Go实际State/race以及同次NDK生成头与JNI链接通过。旧公开源码扩展17场景有16失败、5个测试进程异常终止；这不是设备故障率。原preclaim、完整owner及真实CheckJNI/设备另验。回执 `validation/2026-10-07-three-platform/android-jni-checked-release-validation.json`。

TUN 配置预留模块的红绿、独立审阅及核心编译证据见 `validation/2026-10-07-three-platform/android-tun-reservation-validation.json`。预留尚未接入真实启动链，core race 缺离线依赖，不能据此声明设备竞态、CheckJNI 或发行包通过。

配置预留错误码的 Kotlin 生产解析器兼容证据见 `validation/2026-10-07-three-platform/android-config-reservation-codec-validation.json`。验证只覆盖本机 JVM 公开 JSON，不代表 Android JNI 或完整应用。

拒绝输入清理的公开资源计数和完整状态模块 race 证据见 `validation/2026-10-07-three-platform/android-rejected-input-validation.json`；未执行真实 FD/JNI/VPN，不表示发行候选通过。

模式核验证据见 `validation/2026-10-07-three-platform/android-tun-mode-validation.json`，只证明模块和核心编译，未证明设备或发行包。

资源身份回归与同次完成快照证据见 `validation/2026-10-07-three-platform/android-owned-state-validation.json`；公开Resource不代表真实FD/JVM/设备。

输入处置与重入红绿证据见 `validation/2026-10-07-three-platform/android-lease-disposition-validation.json`；没有实际Android FD/Android JVM/CheckJNI或新APK验收。

JNI实际启动入口对领取前global ref删除检查并清除异常，失败保存库生命周期cleanup unknown；Java claim异常同样保存移交未知。未知责任阻断后续启动，stop仍尝试Go资源回收但不得报告整体成功。六项公开函数表ASAN场景修复前有三项失败，修复后全部通过；既有17项释放、9项故障回归及NDK28/API26 ARM64生产JNI链接通过。该证据不覆盖真实JVM/CheckJNI、并发准入、typed owner或新APK。

Android Go新增带epoch/configRevision/generation的startTUNOwned/stopTUNOwned C导出。生产桥在配置锁内预留并复制构造值，锁外调用State和实际NativeTun，最后锁内核验；拒绝输入从同次State报告捕获旧资源身份，stop须同时匹配reservation与State。准备异常、输入/关闭未知保留阻断，fd0仅在非VPN模式采用。九项桥接测试含两项单侧身份漂移、全core CGO0、startup race、NDK28/API26 ARM64 c-shared及同次JNI链接通过，ELF包含两个导出符号。JNI/Kotlin调用方、旧FFI/HTTP/quickStart配置和启停旁路尚未采用/收敛，不能将该ABI候选称为完整客户端或设备验收。

Android新增startOwnedTunNative/stopOwnedTunNative JNI入口，传递epoch/configRevision/generation至Go；领取前失败收尾检查引用删除，普通负claim调用空负输入取得Go报告，Java领取异常或JNI清理未知不进入新启动。Go C堆回执始终在Java字符串转换后释放，stop先尝试Go按身份收尾，JNI未知时返回null。Core新增Raw调用，OwnedTunInvocation在finally关闭未领FD之后捕获不可变输入快照，异常/null/关闭失败粘滞阻断。九项生产JNI函数表ASAN、六项Invocation JVM行为、完整Core/TunInterface对公开Android SDK jar编译、旧17+6+9项JNI回归和NDK同次头链接通过。该验证未执行Core/ParcelFileDescriptor的实际运行；严格owner解析、VpnPlugin采用、并发事务及旧旁路收敛仍未完成，不能声明新入口已启用或发行包可用。

Android NativeTunProtocol严格解析Go固定十四字段及大小写敏感的资源身份，校验request/operation、outcome/phase、配置代次、资源快照与VPN模式；拒绝重复键、尾随值、非规范整数、溢出、非法Unicode/转义及错误类型。NativeTunCompletion在Core finally后核验输入处置：Go成功start必须与CLAIMED一致；本地未确认、bridgeBlocked、null或协议错误统一unknown+blocked，保留已成功解析的原生责任。可编译占位契约RED失败、生产解析和最终完成夹具GREEN通过；真实Go生产桥生成九种公开回执后由Kotlin直接消费，通过既有配置parser回归及独立审阅。解析器仍用全局错误码白名单，未按操作分区；实际唯一owner/VpnPlugin采用、真实FD/CheckJNI及新APK另验。

Android实际权限启动路径使用进程内动态请求码与同次弹窗共享结果；拒绝、无Activity、prepare/launch异常及正常detach/engine退出逐请求一次完成false。配置变更保留在途请求并向新Activity重新注册监听，迟到旧结果不完成新请求；授权成功先核验原始intent再初始化service engine。冷恢复后的权限请求切Main，prepare异常不再被当成授权成功。生产controller公开JVM回归及独立复审通过，实际Android release Kotlin工程离线编译退出0且源码不漂移；新APK安装、设备旋转/权限弹窗及真实VPN流量另验。证据见 `validation/2026-10-07-three-platform/android-vpn-permission-validation.json`。


Android普通stop/stopVpn响应等待同次native工作门禁中的TUN关闭、平台资源关闭和匹配代次的STOP提交；失败返回false并保留阻断与未确认绑定责任。Dart两个普通停止包装器对false/null抛出现有本地化错误，后台引擎显式调用Vpn.stop，运行时间与偏好只在普通停止确认后更新。JVM屏障回归与真实release Kotlin工程编译通过；Dart实际包装器红例复现2项失败、修复6项通过，完整Flutter测试225项通过。smartStop、typed owner、关闭后engine ACK及新APK设备验证尚未完成。调用方等待响应期间暂留engine，不能据此宣称完整关闭或发行可用。

静态分析无问题，独立原生/Dart审阅未发现P1/P2。GlobalState分支仅静态审阅；listener先关闭而Native失败时保留状态，可能形成部分停止态。相关证据：`docs/validation/2026-10-07-three-platform/android-stop-completion-validation.json`。


## shutdown失败传播与engine退出前置条件

shutdown监听失败传播已接入生产handleShutdown：runLock内关闭新监听准入并调用StopListenerChecked，未确认即返回false，保留isInit与失败对象，不执行executor清理。Android ClashLib.shutdown使用completeShutdown，关闭false或异常不销毁，关闭成功后等待destroy；destroy仅在Service回执严格true时成功。Go公开登记监听的实际红例证实原失败吞没、初始化状态丢失及重试责任丢失；固定源版本的失败/成功与stop action回归通过。该改动不证明executor、provider、controller、TUN drain或全部runtime资源退出，不提供engine退出资格。

安全engine退出必须使用同次不可变stop票据，固定原生调用messenger/session和目标engine对象/序号，checked收尾与消费ACK均关联该票据；销毁前原子检查最新intent、配置/权限/绑定操作、未确认资源及目标身份，设置EXITING并在主线程锁外销毁，退出期间排队新启动。Service.destroy、internal autoDestroy及_initService旧destroy入口需共同收敛；当前尚未实现。现有init/getIsInit未统一锁、排队startListener可重新准入，布尔成功不得成为退出许可。

当前固定源版本Go主包完整回归、失败/成功shutdown和stop action定向回归、230项Flutter测试与静态检查通过。证据：`docs/validation/2026-10-07-three-platform/shutdown-completion-validation.json`。


## 后台检查式监听关闭实际接线

Android后台停止监听使用invokeAction的检查式Go动作，confirmListenerStop只接受同次id、stopListener方法、整数code=0与严格data=true；失败、畸形、缺字段或异次回执均不能确认成功。GlobalState后台与ClashCore公开停止入口对false阻断本地状态清理；ClashCore.withInterface供隔离行为验证，ClashLibHandler.withLibrary初始化测试库但不替换生产单例。生产默认库名libclash.so保持一致。

真实ClashCore红例1失败、修复6项定向回归通过；本机darwin-arm64实际Go c-shared库经生产ClashLibHandler连续两次停止消费成功回执，库摘要在执行前后保持一致；237项Flutter完整测试及静态检查通过。非移动cgo文件lib_non_mobile.go与!android && !ios && cgo条件一致；其移动平台和非cgo分支仍各自独立。

FFI用例为新加载库且无登记监听资源，不能证明Android JNI/Binder、真实TUN、关闭失败跨FFI或全部runtime退出。关闭失败由Go公开登记监听回归与Dart协议回归分别验证。GlobalState后台副作用仅静态审阅；invokeAction缺失回执仍可能无限等待。统一Native owner、配置/TUN接线、epoch、engine session/ACK与EXITING准入尚未完成。

证据：`docs/validation/2026-10-07-three-platform/listener-stop-ffi-validation.json`。


## Android 2011be5 正式签名候选设备验收

源提交2011be5a5b9cbf9e21fdaeca6aadc27c95c49aa1完成完整release构建，构建入口使用项目批准的官方依赖网络边界；签名证书锚、12项APK库检查、来源与锁文件不变检查通过。不可变本机产物为build/releases/android/Bettbox-arm64-2011be5.apk，SHA256为1ddd8c675a14b75d3d37cfaf7e08f7476646f5a75268479dafe46fa1bb6a4afb。

现有Pixel_7 ARM64模拟器SDK36保留数据安装成功，设备回读APK摘要匹配。实际首页显示，未出现该应用的crash buffer记录；无前台服务且connectivity中的VPN transport仅为请求后，执行冷启动，返回首页且没有密码输入表单。该证据不单独证明账户接口、订阅刷新或安全存储内容正确。

实际普通启动/停止两轮通过：启动时间、前台VPN Service与VPN网络对象同时出现，普通停止后就绪界面恢复，前台服务及VPN网络对象撤销。首次点击未进入运行态尚未定位根因；冷启动后的启动操作成功，不将早期握手日志视为已确认根因。规则模式下Chrome HTTPS请求返回ERR_CONNECTION_CLOSED；直连模式与无VPN对照显示当前网页正文。测试网页当前不含旧Example Domain标题，验收按实际正文和错误页面进行。尚未证明Chrome包路由范围、Mihomo数据计数及代理节点流量，直连结果不能替代规则转发验收。测试结束恢复规则模式并确认无前台服务或VPN网络对象。统一Native owner、配置/TUN接线及engine退出合同、邀请注册/佣金、支付全路径仍待验证，release_verified保持false。macOS完整客户端启动与正式发行签名另验，空白监督探针不作为正常界面验收。

公开回执：validation/2026-10-07-three-platform/android-2011be5-apk-validation.json。


## macOS 开发Keychain原生准入诊断

独立原生合成键探针经现有Apple Development身份签名，实际无权利且严格验签通过；使用固定独立服务和新UUID，不读取业务凭据、不修改ACL或搜索列表。两种命名空间均确认不存在后才写入；普通查询匹配锁定Darwin插件默认WhenUnlocked，删除移除此约束。首次及覆盖写入均返回0、合成值读回匹配、指定本地条目删除后确认不存在。

同步存在查询返回itemNotFound，同步删除却返回-34018；按锁定Darwin0.3.2删除判定，首次本地删除成功掩盖同步错误，重复删除返回-34018。因此三个MacOsOptions参数不足以证明开发会话重复清理可用，开发存储尚未采用，正式DP配置与权利未变。原生夹具不是完整Flutter插件或App验收，不证明冷启动和账户安全存储。六项工具边界测试通过，独立审阅两项P2修正闭合，合成条目已确认清理。

证据：validation/2026-10-07-three-platform/macos-development-keychain-validation.json；计划：../.agents/plans/2026-10-09-macos-development-keychain.md。完整macOS启动、开发存储适配和发行签名仍待验收。

## macOS 完整本机开发候选

2026-10-09，`build/macos-local-development/Bettbox.app` 完成完整 main 入口构建与 Apple Development 封装，CUA 确认实际首页与导航显示，系统代理和 TUN 关闭、无配置。空白 supervisor 探针已结束，不能把探针黑色窗口当作产品界面。公开回执为 `validation/2026-10-07-three-platform/macos-local-development-launch.json`。

构建命令为 `python3 scripts/validate_desktop.py --target macos-arm64 --execute --unsigned-macos --local-development-keychain`；封装命令为 `python3 scripts/seal_macos_candidate.py --signing-mode apple-development --local-development`。执行前须通过 PDEC。开发 Keychain 使用独立 service 与显式构建开关；正式默认 DP 路径保持。封装清单保留 launch_validated=false，实际启动证据由上述独立回执承载。候选未公证、不可作为正式发行；真实插件写读、会话冷启动、系统代理恢复与有效上游流量尚待验收。

## Android 智能停止候选

实际 Dart 包装器 red 两项失败，修复后 12 项 channel 回归与生产 Kotlin gate/lifecycle 的协程屏障夹具通过；release Kotlin 工程编译退出0。公开证据为 `validation/2026-10-07-three-platform/android-smart-stop-validation.json`。失败、空回执、旧代投递和会话换代禁止成功清理。完整 Flutter 与静态分析结果由回执承载。未安装新 APK，实际 Handler/JNI/设备交错与智能恢复未验；不能升级为 VPN 或发行通过。

当前同源独立协议探测见 `validation/2026-10-07-three-platform/node-protocol-observation-2026-10-09.json`。抽样两条 AnyTLS 传输失败及两条 Hysteria2 认证失败只证明相同协议在独立核心也失败，不能确定密码、额度或上游配置根因。

## Android 35b6443 已安装候选

产物 `build/releases/android/Bettbox-arm64-35b6443.apk`，SHA256 为 `f2c949be35c69857e1b3437950dfa0fc5c59a326922846e5187a3cfcc66b44ea`。完整构建、正式签名、源码和锁文件不漂移、12 个原生库 ELF 16KiB 对齐检查通过。Pixel_7 保留数据安装及设备回读同源摘要通过；实际首页、普通停止后前台服务撤销、冷启动返回首页保持停止通过。初次 WARM 启动存在运行计时与前台服务，尚未确定恢复原因。

公开回执为 `validation/2026-10-07-three-platform/android-35b6443-apk-validation.json`。VPN transport 文本须区分活动网络与 NetworkRequest，不能用宽泛文本匹配证明残留连接。本阶段不证明智能停止交错、代理节点 HTTPS、真机或16KiB系统设备；候选不可升级为发行验收通过。

## Android 智能启停实际设备路径

35b6443 已安装候选在匹配当前模拟器地址后，日志确认规则匹配与智能停止，运行计时消失而前台服务保留。清空规则未触发恢复，与 `SmartAutoStopManager._checkCurrentNetwork` 的空规则直接返回一致；这是 35b6443 的已复现缺陷。关闭功能后计时和前台服务恢复。该记录的 VPN 采集器漏识别 WIFI|VPN 组合传输类型，原始 false 字段不能作为确定没有活动 VPN 的证据；仅留有最终停止态网络快照，历史运行阶段的活动网络结论撤回。空规则设备缺陷的修复验收见 a21276f 设备章节。

测试结束已恢复原配置（关闭、空规则）并普通停止，计时和前台服务均撤销。当前 NetworkAgent 的 transport 为 CELLULAR/WIFI 且具有 NOT_VPN；不要把历史事件、NetworkRequest 或 NOT_VPN 字样当作活动 VPN。公开回执为 `validation/2026-10-07-three-platform/android-smart-stop-device-2026-10-09.json`；快速交错、唯一 owner、engine ACK 与发行验收仍待完成。

## 智能启停空规则源码候选

`SmartAutoStopManager` 的设置与网络变化进入同一串行检查；空/空白规则或关闭功能会恢复已智能停止会话，不启动普通停止会话。非空规则缺少地址则保留状态；地址查询期间设置换代或组件销毁时拒绝旧决策。策略 red 有 3 项预期失败，green 11 项通过，完整 Flutter 267 项（真实 Go FFI）及 analyze 通过；独立审阅覆盖决策与生产接线。

公开回执为 `validation/2026-10-07-three-platform/smart-auto-stop-empty-rules-validation.json`，绑定源码摘要。设备复现证据来自旧 APK 35b6443，不能用于宣称修复后设备恢复通过。恢复完成确认的源码候选见下节；a21276f 的普通设备恢复见设备章节，唯一 owner/engine ACK 和有效代理流量须独立完成。

## Android 智能恢复完成确认源码候选

两通道响应绑定同一启动意图与 generation，等待前台收尾和 RUNNING/START，主线程投递时再次核验。RUNNING/PENDING 保持等待；请求来源在接受时捕获，未确认的超时、启动失败与 Binder 断开按原始智能停止语义清理，同代提交 SUSPENDED 并保留重试资格；普通停止仍清除来源。Dart 拒绝 false/null，只在同一会话确认后提交计时和停止标记。

公开回执为 `validation/2026-10-07-three-platform/android-smart-resume-validation.json`，绑定最终源码摘要。客户端 red2 项、生产协程/控制器 red3 类缺陷修复后通过；最终 JVM、完整 release Kotlin 编译、278项 Flutter 回归（真实Go FFI）、analyze 与独立复审通过。原生快照确认仍不等于带身份的 Go engine ACK；前台异常、Binder、主线程延迟、startTime为空的ABA及有效代理流量均不能用源码测试替代；a21276f 的普通设备恢复证据见设备章节。

## Android a21276f 已安装候选与智能恢复设备验收

正式签名产物 `build/releases/android/Bettbox-arm64-a21276f.apk` 的 SHA256 为 `64f077977ea99edc7610a475d132fce4e996c5f81307f18d4d654481ab4a4ef0`，签名证书与既有发行身份一致。完整构建、源码和锁文件不漂移、任务专属 Gradle 清理通过；Pixel_7 保留数据安装，设备回读 APK 摘要一致。普通停止及停止后的冷启动均没有运行计时、前台服务或活动 VPN。

活动网络判定只读取 `Current Networks` 的 `NetworkAgentInfo`，按独立传输标记识别组合类型 WIFI|VPN。35b6443 智能启停记录的旧采集器漏识别该组合，原始 false 字段作为历史采集结果保留并附勘误，不能证明没有活动 VPN；新采集在同一旧 APK 普通启动时实际确认 WIFI|VPN，普通停止后确认仅 CELLULAR/WIFI。

源码测试与设备验收各自绑定版本：`android-a21276f-apk-validation.json` 记录构建/安装/停止态；`android-a21276f-smart-resume-device-validation.json` 记录匹配规则、清空规则及关闭功能的计时、前台服务和系统 VPN 网络。前台异常、Binder 断开、主线程延迟、快速交错、唯一 owner/engine ACK、有效代理 HTTPS 和真机不能由普通恢复路径替代。

SDK36 覆盖安装后实际出现运行计时及活动 VPN，接收器 `PackageReplacedReceiver` 在 SDK36 直接请求启动；安装前的普通停止意图没有保留。这项行为需独立修复和回归，不计作正常冷启动通过。macOS 黑色窗口的原因未确认，界面检查等待解锁；进程存活不能替代渲染验收。候选没有达到完整发行验收。


## Android 首次前台发布确认源码候选

服务接口 `startForeground` 返回同代实际发布结果。首次速度通知返回 false（包括熄屏抑制、智能暂停和旧代拒绝）时尝试基础通知；实际平台调用完成后才更新缓存与前台标记。`performStartCore` 收到 false 不发布 START，当前代执行失败清理。速度构造异常传播到失败清理，不把所有异常描述为基础兜底。

生产 helper 的旧决策忽略速度结果，在基础前台调用次数断言失败；修复后的 JVM 两入口、RUNNING 后同代失败与旧 ticket 拒绝用例通过。完整 Android release Kotlin 编译成功，编译后仅补夹具，生产来源摘要不变；独立只读复审无确认 P1。公开回执为 `android-foreground-publication-validation.json`。源码候选尚未打入新 APK，不能用它宣布熄屏设备、持久更新资格或覆盖安装停止意图通过。

## Android 更新恢复资格源码候选

2026-10-09：旧无条件恢复决策在“没有已确认运行资格不得更新启动”断言失败；生产 JVM 三个入口通过，包含真正文件原子替换、严格内容、缺失/损坏/临时文件、删除兜底、双重失败与存储初始化异常。实际 release Kotlin 编译终态 0 且 BUILD SUCCESSFUL。独立只读复审发现存储 lazy 初始化可中断资源清理，修复后的 provider 异常夹具和编译通过，复验确认源码 P1 关闭。公开来源见 `validation/2026-10-07-three-platform/android-package-restart-validation.json`。

设备尚安装 a21276f，候选尚未产出新 APK。必须验证 Android 私有目录原子移动、用户停止/已运行/首次 PENDING/撤销权限/智能暂停的覆盖安装与条件重评估，以及 Receiver 接受后 Dart 迟到启动交错。双存储故障跨进程状态未知及断电目录持久性没有通过验收；有效代理 HTTPS、唯一 owner 和 typed engine ACK 仍需独立完成。

## Android a35d73f 正式签名候选与更新基础设备验收

正式 APK 已完成受控重试，源码/锁不变、单一正式证书、12个 ARM64库和任务清理检查通过；设备安装回读摘要与构建一致。首轮上游连接限时失败没有改变域名/TLS授权，重试成功。从a21276f停止态首次安装资格候选时更新没有启动；确认运行后更新在手动打开前恢复前台服务与活动 WIFI|VPN；普通停止后更新、手动打开以及最后冷启动均保持无运行计时/前台服务/活动VPN。配置未调整。公开回执为 `android-a35d73f-apk-validation.json`。

智能暂停条件重评估、首次PENDING交错、权限撤销与熄屏速度路径尚未覆盖。唯一owner联合采用及有效节点HTTPS尚未完成，APK是正式签名候选，release_verified=false。Android owned采用后的公共旧配置、监听启停与shutdown已增加同锁门禁，实际旧写及资源关闭失败复现和修复后主包回归通过，配置32轮并发race通过。证据见 `docs/validation/2026-10-07-three-platform/android-legacy-admission-validation.json`；legacy TUN与完整双通道接线待完成。完整接线以 `.agents/plans/2026-10-09-android-single-owner-adoption.md` 为执行计划，不能将现有 helper 或更新资格基础验证等同完整发行验收。

Go 运行时配置 epoch 已使用库载入期公开随机身份；完整主包及身份 race 通过，证据见 `docs/validation/2026-10-07-three-platform/android-runtime-epoch-validation.json`。设备 FFI/JNI 实际同实例证明尚未完成，不能用此源码变更替代该门禁。

后台身份准入已接入现有 FFI invokeAction 与两条原生 channel。288 项 Flutter 回归包含新构建 Go 库的真实往返，但该用例的 JNI 回调为 mock；严格 Native 比较与 engine 归属仅有 JVM 夹具及实际 release Kotlin 编译证据。身份失败先提供关联拒绝 IPC，再有限上报，未知资源不报告 STOP 或销毁。完整 owner/ACK、新 APK 与设备真实身份比对待验，证据见 `docs/validation/2026-10-07-three-platform/android-runtime-identity-validation.json`。

### macOS 黑屏定位入口

当前黑屏原因未确认。现有候选进程存活且标准输出/错误指向 `/dev/null`；统一日志缺少 Dart 启动阶段信息，采样中的事件循环及 Metal 线程不能证明正常渲染。源码接入固定启动阶段标记及10秒等待提示，供带输出捕获的开发启动定位首帧之前的等待。四项诊断行为测试及启用真实Go动态库的292项Flutter回归通过；该证据不代表候选重建、实际窗口或黑屏修复通过。锁屏时不执行窗口验收，也不把首帧回调标记当作窗口正常证据。
