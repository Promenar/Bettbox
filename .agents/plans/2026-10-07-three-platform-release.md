# Android、iOS、macOS 发行实施计划

## 目标与验收

主控优先交付 Android、macOS 与 NoSLA 服务端适配，发行包需可安装、可登录、可购买、可获取订阅和实际连接。iOS 保留开发版并研究发行方案，发行不作为当前交付门禁；用户已明确选择此范围。业务代码保持共享；邀请归属、返佣与余额由 Xboard 计算。Android 使用自有渠道 APK，macOS 使用安装应用；正式发布必须具备对应签名和权限，模拟验证不替代真实支付或 VPN。

## 当前事实与开放条件

- Flutter 3.44.9；Android/macOS/iOS 原生工程存在；iOS arm64 模拟器应用已编译并启动，真机隧道尚未验收。
- 本机 Android 工具链和 iOS 27 模拟器可用；Apple Development 身份存在，团队及 Network Extension 权限未确认。
- NoSLA Xboard 已迁移；API 主入口 api.bingcn.site，邀请网页 cloud.bingcn.site，旧入口保留兼容。
- 付呗插件与订单事务补丁为本地候选，真实 Laravel/SQLite 隔离集成已通过，未部署或启用生产付款；商户号、门店号、通道开通情况待用户补齐，接口密钥不得进入模型或客户端。
- Android/iPhone 真机连接待用户准备；Windows 原生开发不在三端目标内。
- 用户目录 .video_agent 不属于本任务，保持原状。

## 工作包与所有权

1. 主控：共享账户/订阅/域名/日志安全检查与测试，文件为 lib/xboard、对应 test/xboard；登记本机 PDEC 测试与构建入口、发行配置。
2. Android/macOS：先只读核验启动、ABI、签名、权限、Keychain 与 VPN 行为，再确定可独立施工文件。禁止缺内核或缺正式签名时静默交付伪发行包。
3. iOS：先完成基于公开 PacketFlow API 的架构决策，确认 core 编译及包收发接口，再建立 Runner/PacketTunnel、平台桥接、共享容器及 IAP。禁止把桌面 Process 或私有 utun fd 获取作为发行方案。
4. 服务端：付呗适配插件、金额转换、验签、订单入账及回调幂等；Apple 交易验证和通知桥接独立配置。先在隔离测试环境完成，不读取原始秘密或操作真实资金。
5. 主控集成后由未参与施工的审阅者串行审阅高风险实现，按相同 SHA 验证三端与服务端，产物附哈希、版本、签名事实和验收清单。

中央文档、registry、PDEC、HLG 与生成文件由主控串行维护。子 Agent 初期只读，没有写入所有权；施工授权在接口和所有权明确后另行派发。

## 顺序与边界

- 先修复发行基础缺口：服务入口与安全 URL 校验、敏感日志、认证错误处理、依赖与核心缺失门禁。
- 运行共享回归，再做 Android/macOS 原生启动和权限验收，iOS 架构与服务端支付设计并行调查。
- iOS 系统权限、App Group、Keychain 必须使用实际可用团队；可先完成模拟器 UI/业务，但不能标记 VPN 完成。
- 真机网络切换、锁屏/后台、故障重连、账户切换、邀请扫码、支付回调与订阅刷新必须有实际证据。
- 真实支付验收由用户完成付款动作，主控核对服务端回调、入账、套餐和返佣；未获预算不产生交易。商店协议和提交交互按平台权限要求处理。
- 服务端变更先备份数据和配置，测试插件未验收时不启用公开付款；失败回滚代码/配置，不覆盖验收期间新增账务。

## 验收入口

- 共享：flutter test；flutter analyze，按项目基线区分既有问题和新增问题。
- macOS：现有 scripts/validate_desktop.py，正式签名构建另补可验证入口；登录持久化、代理/TUN、休眠恢复实际验收。
- Android：锁定 SDK/NDK/CMake 的 arm64 调试与发行构建，AVD 安装启动、VPNService、真机生命周期和签名验收。
- iOS：Xcode 模拟器编译与启动、签名设备构建、PacketTunnel 真机包收发、IAP 购买/恢复和服务器验证。
- 服务端：单元与隔离数据库测试、重复/乱序/伪造回调、金额和订单绑定、并发幂等、拒绝跨账户入账。

各入口在执行前登记并 validate PDEC；主控按实际结果补充命令与证据，不填造已通过状态。

## Android 官方依赖连接验收

任务仅使用用户授权的九个官方依赖主机与 Cloudflare DoH。连接代理监听127.0.0.1随机端口，只接受白名单host:443的CONNECT，透明转发TLS字节；Java保留原站SNI和默认证书校验。每次上游连接使用原始CNAME/地址最短TTL，TTL0仅用于当前查询对应的一次连接且不缓存，过期回答有界重新解析；已建立的TCP不因DNS缓存到期中断。

只向wrapper与实际Gradle JVM注入任务代理参数，hosts限制为localhost闭包，禁止系统解析回退。禁止系统DNS、Tailscale、全局hosts、全局代理和非官方依赖变化；pub/Go不使用该代理。实现由Android网络工作包独占四个脚本/测试文件，独立审阅后主控登记PDEC、冻结来源，先Java TLS与Gradle help，再APK。清理须验证owned socket/thread/child与Gradle进程退出，回执不保留签名URL或响应正文。

## macOS 权限与状态修复门禁

原生审阅确认现有 root/setuid 整体内核路径缺少调用者鉴权，不能作为安全 TUN 发行实现。下一工作包须定义受限提权接口、连接方身份、配置与文件边界及失败回滚；未完成前不执行该提权路径。启动状态仅在监听与必要权限真实确认后提交，普通代理与TUN分别确认。系统代理操作串行、核对返回码，保存本应用持有的配置并且仅在当前值匹配时恢复，不能无条件清除既有PAC/bypass。Apple Development候选和DeveloperID公证发行分开验证，核验嵌套签名及core签名前后关系。


macOS TUN 架构采用前需完成 Apple 用途约束核验：TN3134 中直接 Developer ID 分发的 Packet Tunnel 必须为系统扩展，应用扩展仅限 App Store；TN3120 限制将所声明的流量通过其它接口代理转发，以及在 Packet Tunnel 内托管网络监听器。当前 Mihomo 规则代理与本地监听行为须逐项比对，不以 iOS 工程可编译推定 Apple 分发适用。受限 fd broker 作为 macOS 独立候选；最终方案、团队权限和真实数据流验收均待确认。依据：[TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)、[TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)。

## Android 原生目标契约

执行入口仅生成ARM64核心并向Flutter传入 `android-arm64`。core库按相同公开 `target-platform` 属性映射NDK ABI过滤，显式未知/空目标拒绝，未传目标保留默认。多ABI构建须分别生成对应核心及头文件；缺失检查不放宽。文件所有权限于android/core/build.gradle.kts与工具契约回归；独立审阅后更新PDEC输入摘要，冻结候选并执行完整debug构建。验收包含CMake实际配置目标、核心/APK ABI、16KB产物、源码锁文件不变与任务进程退出；通过后再安装已有Pixel_7，实际设备页大小4096需单独披露。

App在显式目标且非split-per-abi时覆盖Flutter默认全ABI过滤，split模式由Flutter管理应用过滤，core库始终遵循显式目标。实际候选APK生成与12个ARM64库ELF/16KB检查通过，但含额外架构插件库被最终验证拒绝；修复的实际打包内容独立验收。
