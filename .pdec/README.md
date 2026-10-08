# Bettbox 开发执行契约

## 授权与适用范围

2026-10-07 用户明确授权环境就绪后自主完成 Android、iOS、macOS 开发调试、服务端适配和可用发行交付，本机负责三端开发。登记本机 `test-flutter` 操作（`flutter test`）；具体新增移动构建与设备联调入口在实施时登记，不把既有桌面编译授权当成移动端验收证据。原始支付凭据、签名私钥不得进入源码、日志或 Agent 输入。

用户在 Bettbox 邀请返利和跨平台适配任务中已允许“可配置项开发阶段允许按需调整”，并要求“继续……完成后续内容”。本契约在该项目开发授权内记录桌面编译、必要依赖恢复与验证；不扩大到生产部署、正式签名、商店上传、服务端资金操作或新的自托管执行主机。用户已说明有 iPhone，但 Apple Developer 团队尚未准备好。

## 工程与执行位置

工程为公开 GitHub 仓库中的 Flutter 3.44.9 / Dart 应用，内含 Go Mihomo core 与 Windows Rust helper。源码共用 `lib/`，当前候选分支为 `feature/m1-account-subscription`；不按操作系统建立长期业务分叉。

| 操作 | 执行主机 | 目标 | 入口 |
| --- | --- | --- | --- |
| macOS 编译验证 | 本机 macOS arm64，local | macOS arm64 | `python3 scripts/validate_desktop.py --target macos-arm64 --execute --unsigned-macos` |
| Windows 编译验证 | GitHub 标准 `windows-2022`，github-hosted | Windows x86_64 | `.github/workflows/validate-desktop.yaml` |

既有 `.github/workflows/build.yaml` 为发版 tag 构建入口，保留不变。验证入口单独产出开发候选，不执行发布。Windows 验证由当前 feature 分支相关文件的 push 或人工 workflow_dispatch 触发；每次使用事件绑定的确切 SHA，checkout 到工作区短目录 `s`，将工作区映射到 `S:` 后在 `S:\s` 构建。项目不能位于盘符根目录，否则末尾反斜杠会破坏 Flutter/CMake 环境变量边界。同步和构建触发不共用发版 tag。没有部署 Main/FNOS 的后台同步或任务执行服务。

macOS 当前验证操作为显式关闭 Xcode 签名的编译：保留正式 Keychain entitlement，但不声称签名或登录持久化通过。实际 Xcode 检查已确认该 capability 需要开发证书。准备好团队签名后，再单独完成签名与 Keychain 验收。Windows 验证不读取签名密钥。不同 SHA 的日志和产物以 GitHub run 区分，同工作区不并发执行脚本。脚本默认只检查环境并展示命令，显式 `--execute` 才编译。

## 工具、依赖与证据

- 固定 Flutter 3.44.9；macOS 使用已核验 Go 1.26.x、Xcode 与 CocoaPods；Windows 使用 Go 1.25.x、Rust 1.98.0、Visual Studio/CMake 原生工具链。实际版本由入口打印并核验。
- macOS 编译实测使用 Xcode 27.0、Go 1.26.5、CocoaPods 1.17.0 与 Ruby 4.0.7；系统基线和 Pod targets 为 macOS 12.0。
- 使用 `pubspec.lock`、`core/go.sum`、Cargo.lock、Podfile.lock、Package.resolved。构建不运行 pub upgrade / go mod tidy / flutter clean；锁文件变化直接报告失败，依赖更新另行审阅。
- core 进入 `libclash/<平台>/`；Windows helper 的 IPC 校验值由同次 core SHA256 生成。Flutter 构建使用该摘要。
- `.gitattributes` 为 7 个 Flutter 平台生成文件固定 LF；Windows checkout 与生成器采用相同换行。源码与锁文件漂移检查保持启用。Windows CMake 安装步骤包含 `native_assets/windows`，用于交付 SQLite 等 FFI 原生依赖。
- 本机产物位于 `build/macos/Build/Products/Release/Bettbox.app`；Windows bundle 位于 `build/windows/x64/runner/Release`。入口检查文件存在并输出 SHA256。原生编译成功仅证明构建能力，实际代理连接、系统浏览器、Keychain 冷启动及权限仍须设备验收。
- Windows job 有有限超时，runner 随 job 回收；不使用家庭自托管 Runner，不向候选代码传入生产凭据。缓存按平台与依赖锁隔离；开发产物保留期由 workflow 声明。
- 本机依赖由现有 Flutter/Go/Cargo 缓存和 CocoaPods 管理，不自动清理用户缓存。一次性构建不开放服务端口；停止可中断构建进程，清理仅针对明确的项目生成目录。

## 平台范围与回滚

登记本机 macOS arm64、iOS arm64 核心构建及共享测试；Windows x86_64 保留既有 CI。Android arm64 本机开发构建使用项目扩展，不把一次架构结果外推到其它架构。iOS 系统 Packet Tunnel、App Group、签名和 IAP 验证独立于静态库编译。

开发候选通过 GitHub artifacts 或本机文件交付，不传送到生产服务。生产目标、健康检查和发布回滚均未启用。回退本任务提交即可恢复客户端与构建配置，既有 tag 发版入口持续保留。面板的只读/隔离集成测试属于既有服务诊断，不通过此契约授权真实用户或资金变更。

变更范围为构建脚本、验证 workflow、契约及相关项目文档；客户端差异与测试另见 `docs/PLATFORM_VALIDATION.md`。执行前运行用户级 PDEC `validate --root`，要求 `execution_ready=true`；契约所引用的脚本或锁文件变化后需重新核对授权范围和摘要。

## Android 平台扩展

统一 PDEC 校验器的操作平台枚举尚未包含 Android。`contract.yaml` 的 `platform_extensions.android` 保留真实 Android arm64 目标；统一批准摘要覆盖该字段。`scripts/validate_android_contract.py` 先调用已安装的统一校验器，再严格核对本机主机、目标、命令、产物与超时范围。

`build_android.py --execute` 强制执行两级校验，并将批准摘要写入回执；统一校验器位置通过 `BETTBOX_PDEC_VALIDATOR` 或 `--framework-validator` 提供。本机用户明确授权三端调试，执行主机为 Apple Silicon Mac。默认生成 debug APK；显式 `--release` 使用 `platform_extensions.android_release`，项目验证器以 `--release` 核验准确命令、产物与2700秒预算。密码只注入 APK 构建进程，工具正文丢弃，生成后必须核验单一正式证书、核心、原生库对齐和来源；安装与业务发行验收独立完成。

Android 每次构建采用独立 Gradle 用户目录，总体预算 2700 秒，子进程超时后进行仅限本任务的终止核验。不能证明进程归属或退出时记录失败。源码、锁文件、核心和 APK 哈希及退出证据位于 `.test/android-build/receipt.json`，该目录不提交。

## iOS 与服务端隔离验收入口

`typecheck-ios-native` 使用实际 Simulator SDK 检查共享原生代码及 PacketTunnel 类型；`build-ios-simulator` 验证 Runner 和扩展完整构建。两者不签名或证明系统 VPN 可用。核心 XCFramework 由锁定源码产生，放入 ios/Vendor，二进制不进入 Git。

`test-billing-isolated` 通过既有 SSH 身份传输精确公开 fixture 清单，在 NoSLA 当前 PHP 镜像的128MiB禁网只读容器内执行多进程 SQLite 验收。仅一次性工作目录可写；源码、清理和镜像身份纳入回执。该入口不挂载业务数据库、配置或环境秘密，也不启动真实收款。

原生iOS测试入口为`test-ios-native`：在已有iPhone17 arm64模拟器上执行RunnerTests，结果不外推真机VPN。Android官方网络入口使用任务loopback CONNECT，32条有界转发与6条解析/连接并发分离，排队12，逻辑转发缓冲上限16MiB；回执包含固定代理拒绝计数，不能用零计数单独判定官方源健康。当前142项网络、构建、契约及签名测试通过，历史版本隔离复现确认两项缺陷修复，实际依赖门禁另行验收；不修改系统代理或DNS。桌面源码冻结纳入未跟踪输入字节，macOS使用目录句柄拒绝链接；Windows回退检查reparse point，实际Windows句柄竞态行为未验收。

`test-android-regressions` 只对固定公开历史候选与当前实现做回环/mock对照，不发送进程信号。`test-macos-proxy-core` 在本机运行无外部依赖 Swift package 的23项事务测试，输出位于忽略的任务构建目录，不访问真实系统代理。

Java候选发现使用公开ucomm，只同UID的java候选查询内核身份；它是发现线索，不授予信号权限。源外目标诊断只有固定枚举，不保留hostname/headers。QJS仓库使用Google和Maven Central，保留现有依赖版本；Wrapper的8.14-all发行ZIP固定官方SHA256。

`test-android-distribution-cache` 验证项目内官方发行ZIP独立预置，包含33项无网络夹具。实际构建TLS门禁通过后才预置，SHA和副本稳定性校验通过后仍执行Gradle JVM门禁。源码包括4个Wrapper文件，其8.14 JAR与发行ZIP各自固定官方SHA；预置不复制Maven/编译缓存，也不改变9host授权。

ARM64实际构建已通过官方ZIP复用、Gradle help/JVM门禁与退出清理，APK失败根因是core模块未继承Flutter目标ABI；其build.gradle.kts纳入PDEC输入证据，目标过滤修复的完整构建独立验收。

App原生打包配置纳入输入摘要；显式Flutter目标覆盖默认全ABI过滤。真实b6d7a58 APK编译成功但最终ABI拒绝，不能当作发行产物。

Go核心在库与App打包中保持原始字节；AGP默认strip转换已真实复现，builder仍严格比对生成核心与APK SHA，未改为宽松内容比较。

Android APK 门禁还核验动态段地址与文件范围一致、依赖 basename 及 JNI 的 libclash.so 依赖。项目签名文件保持0600，系统钥匙串接受同UID、禁止他人写入的现有权限；安全读取不修改系统ACL。实际149项工具测试通过，设备与正式构建另验。

2026-10-08：test-macos-blind-http 在本机执行新专用 HTTP 包的 -race 测试，固定只读依赖锁及离线依赖缓存；不启用系统代理、不修改网络设置。用户三端开发授权覆盖该 Apple 本机操作，入口失败不扩大网络权限。

2026-10-08：test-macos-owned-pipe 按现有 !cgo 生产tags本机CGO0编译与普通协议fixture验收，离线只读依赖。该命令不使用-race（工具链要求CGO1），不证明宿主身份、内核管道背压或实际退出。

macOS owned-child fixture 使用固定任务产物，公开协议帧与预填内核管道，不读取用户配置或注入认证；仅终止captured child并wait。正式宿主身份接线、业务路由、系统代理与发行签名单独验收。

2026-10-08：test-client-state 仅本机CGO1 Go状态包race；原子JSON提交、深复制与并发fixture，不运行核心/系统代理。共享Go ordinary test是接口回归，Android/iOS原生候选另行编译验收。

`test-android-preflight` 在本机离线执行 Android 快速配置前置 helper 的 CGO1 race；初始化或状态失败不再执行 setup，adapter 仅一个回执发送调用点。旧调用顺序薄包装器的两项失败复现和四个修复后子场景已运行；这不证明 JNI/设备启动、真实 bridge 投递或跨引擎取消完成。

`test-android-preflight` 覆盖整个生产 `androidstartup` 包，含资源提交、FD采纳责任、回调准入和首次关闭错误保存的15个新增fixture。完整Android adapter尚未接入这些资源helper，CGO1普通宿主race不代替Android JNI或设备验收。

`test-macos-build-identity` 与 `test-macos-setup-identity` 验证共享最终签名入口和打包参数。macOS core 固定使用系统 codesign ad hoc 签名后重新绑定文件，verify/display期间保持新产物稳定；Xcode宿主的关闭签名选项不跳过此步骤。实际副本签名与独立验签通过，完整bundle和发行资格另验。临时JVM/native身份fixture仅登记于运行时契约，不将忽略目录输入作为持久构建依赖。

## 隧道构造输入回归

`test-tunnel-constructor` 在本机core目录离线运行生产TCP/UDP构造器race测试，目标与绑定器均为公开虚构夹具，无系统代理、账户或公网调用。该回归只确认无效目标零绑定及合法绑定错误保留，不构成Android/iOS/macOS发行或完整原生生命周期验收。

`test-listener-close` 使用离线CGO1 race验证已登记资源关闭事实；`test-macos-owned-pipe` 使用CGO0/with_gvisor验证实际Go专用控制入口，`test-macos-blind-http` 使用CGO1 race验证专用HTTP及Endpoint。三类证据分开，不把Go capability或Close nil升级为宿主身份、系统代理或完整VPN退出证明。
# macOS supervisor 模块验证

`test-macos-supervisor` 在本机 macOS arm64 运行 `python3 scripts/check_macos_supervisor.py --execute`；`test-macos-supervisor-tools` 检查验证器来源绑定和fixture构建隔离。固定生产源码位于 `macos/CoreSupervisor`，工具编译当前SDK并运行authority/owner fake与公开true/sleep child。不签名、不修改系统代理，不表示客户端接线或发行包完成。

`test-supervisor-session` 验证实际DartSession；`test-supervisor-host` / `test-supervisor-host-recheck` 支持宿主定向行为回归。`test-macos-supervisor` 同时编译无fixture宏的生产helper，覆盖relay满pipe、取消、迟到SDK与Core假控制帧。`test-supervisor-production-signed` 使用唯一输出名、冻结actual源、公开framed Core和adhoc签名验证真实六ABI；不修改系统代理或启动客户端，也不代表Mihomo/发行验收。输出目录已存在时拒绝覆盖，新执行须使用新登记的输出名。`test-supervisor-signed-parser` 只检查完整固定输出分类，不证明native身份。

`test-supervisor-real-go` 使用固定任务产物及预登记SHA，冻结真实Go字节后签名并经生产helper/native host验证getIsInit与退出；不启动系统代理，不等同完整Flutter验收。输出目录已存在时拒绝覆盖。Runner源码与桥接头已纳入编译输入；Debug身份不用于生产链验收。

`prepare-macos-supervisor` 编译固定arm64 helper生产源快照，签名后刷新FD绑定并最后发布身份清单；macOS完整验证在Flutter之前执行该步骤，Xcode仅复制已签产物。`seal-macos-candidate` 保留源App并在独立目录制作最终ad hoc候选，由内到外签嵌套框架与宿主，保持Core/helper字节；已有App或seal.json拒绝，清单排他no-follow发布。`test-macos-packaging-tools`覆盖固定身份、字节漂移、链接/特殊文件及发布失败。三者不修改系统代理、不公证、不发布。独立Flutter新会话已验收，应用主流程另验；共享setup不删除Pod锁，当前helper打包仅覆盖arm64。

`probe-macos-flutter-supervisor` 在固定独立入口构建真实Flutter引擎，绑定两个探针输入摘要及预登记Core/helper摘要，连续运行两代getIsInit与每代16个公开child；退出、双管道EOF及native停止均确认后才通过。原正常App完整文件摘要恢复，源码和锁核验纳入成功条件；未知owner保留，不强杀、不创建新代次。固定探针候选采用无entitlements的ad hoc签名。正常候选保留Release钥匙串权利，严格验签不能证明AMFI允许启动；其签名与安全存储另验。实际两代通过回执为 `docs/validation/2026-10-07-three-platform/macos-flutter-supervisor-validation.json`。

`test-supervisor-rpc` 覆盖生产RPC、就绪判断、Application协调策略与真实ClashMessage派发；Session证据在协调器测试中明确为fake。实际负例复现早回包后sender失败/挂起、旧initial错误/新tail漏等和多listener中途throw，保留回归。`probe-macos-flutter-supervisor` 的独立入口使用同一生产Application/RPC两代真实Go getIsInit与退出；不加载账户或启用SC。正常main、正式Keychain签名和专用HTTP/SC路由独立验收，不能用该探针宣称可用发行。

预检恢复保持现有host/Session/full-test/analyze执行位置，新增同代原生停止确认不改变构建/部署权限。输入摘要已更新；184项Flutter测试与host fixture不替代完整应用发行验收。

`test-macos-proxy-core`覆盖SystemConfiguration候选SDK编译、HTTP-only事务及只读数量验收。测试不调用真实stage/commit/apply，不读取Keychain或输出原始配置。schema3与新SDK源码已绑定输入摘要；不能视作完整App或代理写入验收。

`test-macos-proxy-core`同时覆盖受保护journal真实私有文件与跨进程flock；46项测试仅在任务私有fixture目录发布记录，真实SystemConfiguration仍只读，不代表正常App系统代理写入验收。

Android任务代理拒绝记录仅投影固定类别：非CONNECT、非法authority、未批准CONNECT域名及固定公开候选；候选标签不赋予联网权限。固定HOSTS与HTTPS/TLS门禁保持，任意目标、请求头和URL不进入回执。诊断回归及构建工具93项测试通过；真实正式APK重跑与验签结果单独记录。

正式构建真实拒绝maven.google.com后，按既有本项目官方依赖授权加入该精确HTTPS别名；[Google官方仓库说明](https://developer.android.com/build/remote-repositories)确认其与已批准dl.google.com仓库对应。任务代理共十个官方主机，其他未知目标继续拒绝，未改变系统配置。

`boot-android-release-emulator`仅启动既有Pixel_7并固定5554端口；Android安装/启动登记在platform_extensions.android_release_install/launch，安装前绑定APK SHA与AVD名。正式com.appshub.bettbox与debug包并存，不卸载或清除调试数据。模拟器作为日常开发进程保留；构建任务进程和网络租约已独立清理。


协议诊断在本机使用当前离线Go依赖：`GOTOOLCHAIN=local GOWORK=off GOPROXY=off go test -mod=readonly ./cmd/nodeprobe` 与对应build项均在core目录执行；二进制保存 `.test/android-node-probe/nodeprobe`。执行器回归为 `python3 -m unittest scripts/tests/test_probe_node_subscription.py`；真实探测入口为 `python3 scripts/probe_node_subscription.py`，需本机已安装PyYAML、受保护开发账户及已构建探针，缺失时拒绝而不自动安装或创建账户。执行前要求PDEC无漂移且execution_ready=true。只输出脱敏回执，不付款、不发布、不改系统网络；结果不能代替Android或macOS发行验收。


原生FD合同验收为 `GOTOOLCHAIN=local GOWORK=off GOPROXY=off go test -mod=readonly -v github.com/metacubex/mihomo/listener/sing_tun`，cwd为core，使用项目当前替换依赖。测试不创建系统TUN；真实JNI/FD/三栈及设备流量另验。构造源与测试摘要登记在契约中。

`probe-macos-sc-lock` 只执行当前SDK编译及普通宿主非阻塞配置锁/释放、偏好签名比较，不暂存、提交、应用、提权或请求系统授权。`generate-localizations` 使用既有锁定intl_utils，由七种ARB生成当前国际化文件。


`test-macos-seal-tools` 验证封装工具的两种签名模式与固定失败边界。`seal-macos-development-candidate` 显式使用现有唯一Apple Development身份；证书和签名工具输出在本机捕获，不向模型输出身份姓名、Team值或私钥。已有候选先保留任务内备份，拒绝覆盖；Core/helper不重签，Release entitlements保持项目配置。该操作不公证、不发布、不启用系统代理；完整应用运行另验。


`test-core-listener-stop-action` 在本机CGO0/with_gvisor、离线依赖下运行生产Go handler/action回归。公开InboundListener替身经正式登记入口注入，覆盖失败、panic、去重、其它资源继续关闭和显式重试；不建立系统TUN或访问公网。core全包回归复用 `test-macos-owned-pipe` 的相同Go命令，证据不升级为设备或完整runtime验收。


`test-core-config-prepare`验证生产setup早失败时保留已发布指针、默认URL及调用输入，覆盖纯复制数值语义；CGO0/with_gvisor、离线依赖。`compile-android-config-prepare-core`及对应JNI操作在独立目录使用NDK28/API26编译实际Android ARM64源码，不覆盖原ABI产物，不安装或启动VPN。编译成功不能代替真实JVM/CheckJNI和设备业务验收。

同步配置验证登记test-android-owned-config、test-android-owned-options、test-android-config-protocol-green、compile-android-owned-config-core/jni及test/run-android-config-jni。公开JSON与函数表不使用账户、VPN或网络；产物保存在独立.test/android-owned-config-abi，不覆盖已安装APK来源。state race和全Core回归复用已登记入口。

启动报告验收入口：`test-android-start-report`、`test-android-start-report-first-error` 和 `test-android-startup-full` 使用公开内存资源执行真实生产State/Shutdown及race；`compile-android-start-report-core/jni` 在独立目录编译Android ARM64生产ABI，不安装或启动VPN。macOS候选启动通过已安装CUA工具入口登记，不能将该登记值当作CLI命令。封装工具回归只签公开无权利夹具；真实App的profile和启动另验。

JNI检查式释放验收使用任务独立产物：`compile-jni-release-red-expanded` 绑定ab664741公开旧源/旧真实Go头，`compile-jni-release-green` 使用当前Go生成头及生产JNI，runner逐个执行17个公开case并关闭测试进程core dump，不记录原始stderr。Go固定状态与真实State回归由 `test-android-jni-release-confirmation` 执行；Android实际新c-shared/JNI由 `compile-android-checked-release-core/jni` 构建，既有9/17 JNI负例在同任务目录回归。结果不外推真实JVM或设备。

TUN 配置预留验证入口：`test-android-tun-reservation`、`test-android-config-reservation-regression`、`test-android-tun-reservation-race` 和 `compile-android-tun-reservation-core`。race 需要完整离线 CGO 依赖；模块测试不代表 JVM 或真实 VPN 验收。

`test-android-config-reservation-red/green` 使用缓存 Kotlin/Gson 验证预留错误码的原生 parser 合同，输出为独立 `.test/android-config-reservation-*`。

`test-android-rejected-input` 验证独立拒绝输入清理；完整状态模块 race 使用 `test-android-startup-full`。公开替身不操作真实 FD/VPN。

`test-android-owned-state`验证受管State完整身份；全模块race使用`test-android-startup-full`，Android核心编译使用`compile-android-tun-reservation-core`。

租约处置验证使用`test-android-lease-disposition`、`test-android-fd-lease`、`test-android-startup-full`和`compile-android-tun-reservation-core`。缓存JVM夹具只操作公开数字与关闭计数。

`test-vpn-permission-red/green`验证权限controller公开JVM行为；`compile-android-permission-adapter`使用缓存官方Gradle8.14入口和独立offline缓存，发行凭据仅由既有本机signing_environment注入编译进程。实际release Kotlin工程编译通过，不替代正式APK、安装及设备授权验收。


Android普通停止新增独立JVM red/green输出、release Kotlin适配编译及Dart channel回归操作；均沿用已批准本机例外。原生编译证据不代替APK安装或真实VPN流量验收。


Go shutdown监听确认与Dart关闭/销毁顺序采用已批准本机开发例外运行；测试使用公开登记监听替身，不创建TUN或真实代理入口。真实engine身份与ACK设备验证独立完成。


本机监听关闭FFI验证构建darwin-arm64 c-shared库至`.test/listener-stop-ffi/libclash.dylib`，通过`BETTBOX_TEST_CORE_LIBRARY`注入Flutter测试。测试校验真实路径并调用生产后台handler；默认无该变量时仅跳过这项跨语言测试。此操作不安装动态库、不创建系统TUN或代理，不代替Android JNI和设备验收。


`probe-macos-keychain-options`在本机使用现有唯一Apple Development身份签原生合成键探针，固定独立service与新UUID，两种命名空间不存在才写入；不读业务秘密、不改ACL/搜索列表。实际结果区分写入、覆盖、删除和重复删除，退出0只表示诊断完成且清理确认，不证明插件或App可用。异常保留同次case定位合成条目责任。`test-macos-keychain-options`使用公开替身验证输出边界和失败责任，无实际Keychain调用。

## 完整 macOS 本机开发渠道

`build-macos-local-development` 使用显式 `--unsigned-macos --local-development-keychain` 构建完整 main 入口，固定 APP_ENV=local-macos-development 和开发存储标记。`seal-macos-local-development` 使用现有唯一 Apple Development 身份、独立空权利文件与固定新目录 `build/macos-local-development/Bettbox.app`，拒绝覆盖；按清单校验实际宿主和 App.framework/Versions/A/App、原生 Core/helper 字节。封装成功不声明启动、公证或发行通过。启动记录另存公开回执，正式默认存储与 Release 权利保持。

智能停止沿用 test-android-stop-dart、test-android-vpn-work-gate、compile-android-stop-response-adapter 与完整 test-flutter/analyze 操作。测试使用公开 channel/会话对象与协程屏障，实际 Android release Kotlin 编译使用既有安全签名注入，不回显凭据。该阶段不安装新 APK，不把 JNI void 挂起无异常作为 engine ACK。

`launch-macos-local-development-trace` 直接运行已严格验签的本机开发候选并捕获启动输出，旧候选宿主及两个内核进程必须先确认退出。原始日志只保存在任务目录的0600文件中，模型仅读取固定阶段和状态；启动与帧回调不代表窗口、钥匙串账户、系统代理或发行验收。该入口不启用额外系统权限或付款。

Android 挂起验证使用本机既有 Kotlin 缓存编译真实 SuspendModule 与公开平台桩，8 个行为场景不访问真实 Android 广播或 JNI。checked suspend 的 Android ARM64 核心使用只读离线 Go 依赖与既有 NDK28；JNI 夹具使用该实际生成头文件，15 个场景仍不是设备验收。Release Kotlin 安全注入现有签名环境，仅编译、不安装。

首次初始化配置 kind5 的本机验证使用既有离线 Go/NDK 工具链；真实核心主包、监听登记与关闭 race、生产 Kotlin 协议夹具及 Release Kotlin 编译分别验收。实际 ARM64 输出在 `.test/android-initial-core/`，不覆盖已安装候选，也不安装、启动或发行。

`test-listener-factory-preflight` 使用真实 HTTP/SOCKS/Mixed 工厂和 loopback 端口进行 race 回归；合成 TLS 身份仅在进程内消费，客户端启用证书校验，不调用公网、真实节点或用户凭据。`compile-android-factory-core` 输出独立 ARM64 核心目录，不覆盖已安装候选。

`test-laravel-isolated` 冻结 61 个公开输入，在禁网只读临时容器内执行固定单文件 Migrator、真实 ConsoleKernel 命令及 DDL/仓库 INSERT/DELETE 失败原子性；生产库、配置与凭据不挂载。生产自动注册、真实 Artisan 启动、停写/备份和强杀恢复尚未验收。


真实 Laravel 业务并发保持同一禁网临时执行位置、128 MiB 与64 PID限制；两进程只操作本 fixture 空 SQLite，结果只返回固定检查标签。真实 Laravel 两进程、共同起跑、独立重连和操作区间重叠已验证同用户只创建一单、重复取消退款一次、重复通知开通/流量/消费一次、取消与到账合法赢家状态和返佣余额/日志一次。197 项检查、56 个冻结输入在 NoSLA 禁网只读 128 MiB 临时容器通过；实际进程收尾 deadline 责任缺陷已通过红绿回归修复。仅单轮两进程、旧网关夹具和同步队列，不代表同时等待同一 mutex 的测量、压力测试或真实付呗并发。 生产库、配置及凭据不挂载，其它优惠券限制、生产管理员权限和生产 Redis/常驻队列另验。


真实 Laravel 双进程单轮已验证余额完全抵扣的零金额 checkout：余额扣除、开通和流量重置一次，网关未调用，重复请求不延期；三层 50/30/20 返佣日志及余额各入账一次；购买者参与循环时全部返佣撤销，订单保持已开通、佣金待处理且仅保留一份核对记录。当前 236 项隔离检查、56 个冻结输入及11项执行器回归通过。仅验证该比例及 commission_balance 目的账户，其他比例、舍入政策和普通余额模式另验。 容器执行边界、网络、内存和 PID 限制保持。


真实 Laravel DatabaseQueue/Worker 已在专用 SQLite 队列表验证：CheckOrder 将任务序列化入队且不立即开通；首次开通异常释放任务重试、attempts 增长且业务事务无半次开通；真实 JobProcessed 事件核对两个独立 PID 各消费一个目标任务后队列清空，开通、流量重置和幂等消费者各一次。258 项真实隔离检查、57 个冻结输入与12项执行器回归通过，临时配置恢复。只覆盖有界数据库队列消费，不证明生产 Redis、daemon 信号/超时、failed_jobs终态、强杀或长期压力。 容器网络、内存和 PID 限制保持，未扩展生产权限。


真实 CouponService/Coupon 公开源码已验证两用户竞争全局限用一次的固定金额券：仅一张订单，券次数零，折扣与余额精确，输家无订单且余额不变。创建后的公开故障完整撤销券次数、余额及订单，重试成功。真实管理员 paid 控制器双进程确认只开通/重置一次，无网关调用且重复不延期；身份注入为夹具，不证明生产管理员权限链路。当前 289 项隔离检查、61 个冻结输入与13项执行器回归通过。 公开 CouponService/Coupon 缓存源摘要纳入契约，源缺失或漂移则校验拒绝；NoSLA 执行位置、网络、128 MiB 和64 PID限制保持。


Android启动拒绝传播沿用本机Flutter测试、静态分析及既有离线Release Kotlin工程编译入口；仅刷新ServicePlugin、Dart包装器和新增公开回归的源码摘要，执行主机、网络和签名权限不扩展。没有安装或发行新APK。


Realm生命周期沿用本机公开loopback/race验证，并登记实际Android ARM64 c-shared编译入口。仅新增两项相关操作及两份源码摘要，执行位置、离线依赖、设备和生产权限保持。编译产物位于任务独立目录，没有覆盖既有APK或安装。
