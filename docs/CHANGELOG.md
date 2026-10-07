# 版本变更记录 (CHANGELOG)

## 2026-10-08

- 当前Dart退出线程竞争回收原生child经真实短时夹具复现；macOS原生独占回收方案需统一或隔离父属，未把纯Swift证据标为Flutter生产通过。

- Android 联合候选修复旧Doze回调跨lease影响新连接的问题；23个JVM协调场景、权限归属夹具与20个Go helper/静态接线race测试通过，实际Android/Dart整包接线另验。
- macOS native身份候选SDK编译与9项fake通过；真实launch暴露Foundation独立child进程组，创建/回收合同进入专门诊断，未标记真实guest或完整发行通过。

- macOS core 使用固定 ad hoc 身份最终签名，签名后的文件重新绑定，验签与摘要期间拒绝漂移；共享打包入口和bundle验证核对身份清单，真实签名及34项Python回归通过。完整App、宿主身份与发行资格另验。
- Android协调候选15个JVM生命周期场景编译执行通过，实际Service/JNI整包接线和smart行为尚待完成。

- 增加Android启停资源基础逻辑与回调引用门禁；关闭失败保持所有权，排队回调取消，首次错误粘性保存。基础包race通过，原生整包接线另验。

- Android 快速配置预检在初始化或状态解析失败时立即终止，保留固定错误且只发送一个结果；生产 helper 短路回归经 race 验证。
- 修复客户端状态JSON部分提交、共享列表/指针与并发数据竞争；统一深复制快照，action失败回传固定字符串。4项状态race和22项共享core测试通过，原生启动失败链另验。

- 增加macOS owned-child Go匿名管道入口、单调握手期限与代次隔离；21项普通协议测试及5项真实child退出fixture通过，原生身份和Dart/系统代理接线尚未完成。


- 新增 macOS 专用无代理凭据解析 HTTP/CONNECT 入口与23项实际race测试，包含大文件、EOF、pipeline、停止证据及默认入口认证回归；宿主与系统代理尚未接线。
- Android ea2aa0a 调试APK动态依赖与模拟器起停通过；真实流量和失败路径单独验收，未标记发行可用。

## [Unreleased] - Android 设备加载与签名检查 (2026-10-08)

- JNI 链接对无 SONAME 的 Go 核心声明 `IMPORTED_NO_SONAME`；APK 门禁要求 `libcore.so` 依赖 basename `libclash.so`，拒绝构建路径及不一致的 ELF 动态段映射。
- 项目发行密钥与回执保持 0600。系统登录钥匙串按同用户、无他人写权限检查，读取仍通过固定 security 条目；不修改系统权限或 ACL，保留证书锚。
- Android 调试候选实际安装、邀请生成与网页邀请码预填通过；VPN 启动暴露路径依赖崩溃，修复后的完整构建和设备验收独立记录。

## [Unreleased] - 三端发行基础安全 (2026-10-07)

- API 域名池仅接受无凭据的 HTTPS 根地址；远端引导过滤不安全地址，域名池重排保留当前连接。
- API 与引导请求关闭自动重定向，HTTP 非成功状态不被成功包络掩盖；日志和连接错误不输出订阅凭据。
- Android release 缺少签名配置、原生构建缺少内核或头文件时中止，避免生成错误候选。
- 共享 Flutter 106 项测试与新增 4 项实际 IO 重定向回归通过；静态检查通过。三端完整设备与服务端交易验收另行记录。

## [Unreleased] - 原生核心与服务端事务候选 (2026-10-07)

- iOS 增加 Runner 原生桥、独立 PacketTunnel、App Group 配置快照和内嵌 Mihomo C ABI。设备/模拟器arm64核心与真实SDK类型检查通过，完整 arm64 模拟器应用编译、安装、首页/登录/注册导航与7项原生单元测试已验证，真机VPN独立验收。
- 发行交付优先 Android、macOS；iOS 保留开发版并研究符合 Apple 用途约束的发行方案。
- 配置快照核验完整资源文件集合及运行副本，实际复制预算有界；停止回调独立截止，控制消息保持单在途。
- Dart 接入系统VPN状态、资源清单、模拟器离线能力；成功启动请求不提前显示连接，停止意图贯穿启动预检与配置发布。
- 支付与返佣候选按线上订单源码适配SQLite事务、支付快照、唯一流水、佣金幂等和持久事件恢复；隔离真实SQLite多进程测试通过，真实Laravel隔离集成通过，真实交易待验收，生产付呗禁用。
- Android 增加任务独立Gradle目录、进程清理与核心/APK来源核验；用户允许本项目官方依赖任务级解析及本机正式密钥创建，正式 Android 签名密钥已安全创建，任务官方CONNECT、早期JVM注入与正式签名接线通过142项工具测试，实际TLS与Gradle发行包下载通过；实际APK/签名仍待验收。慢请求头与带空格Java路径清理缺陷经历史版本失败/当前版本通过的隔离复现验证，清理失败保留主失败原因，候选枚举排除受保护的非Java进程、Java读取失败保持拒绝。QuickJS声明仓库限制到Google/Maven Central，版本不变；Gradle发行文件与8.14 Wrapper分别固定官方校验和，4个Wrapper文件纳入来源冻结；项目内完整性匹配的发行ZIP可独立预置，33项缓存夹具通过，不复用Maven/编译缓存。
- Android真实Gradle配置、官方ZIP复用与退出清理通过；定位ARM64任务误构建armeabi-v7a，core原生模块按Flutter目标参数限制ABI，保留缺核心拒绝，真实修复APK待验收。
- Android应用打包按显式Flutter目标过滤ABI，防止ARM64候选包含其他架构插件库；真实APK已生成但最终ABI验收拒绝，12个ARM64库16KB对齐通过，完整修复构建待验收。split-per-abi路径由Flutter管理App过滤，保留core原生过滤。
- Android库及应用保留已去调试信息的Go核心原字节，避免AGP再剥离破坏精确来源哈希；真实NDK复现确认转换根因，修复完整APK待验收。
- macOS 增加串行系统代理事务核心，实际Swift编译与23项fake后端测试通过；真实系统配置、持久journal和App接线独立验收。

## [开发环境] - 本机平台分工与 iOS 模拟器 (2026-10-07)

- 本机负责 Android、iOS、macOS 开发调试，Windows 原生调试使用 Windows 环境，保留现有 Windows CI。
- 安装官方 iOS 27.0（24A434）ARM64 模拟器运行时，iPhone 17 启动及 Flutter 设备识别通过，验证后关闭。
- Android 日常开发共用已有 AVD，其他版本用于兼容性回归；保留 Nexara 使用的现有设备。未创建 Bettbox iOS 工程或执行支付/VPN 验收。

## [运维] - NoSLA 服务端迁移 (2026-10-07)

- Xboard、SQLite/Redis、CloudBridgeRelay、主题补丁、Caddy 和辅助 Mihomo 从腾讯云迁至 NoSLA；冻结快照及 34 张表、35 个绑定资源摘要一致。
- 四条相关 A 记录指向 NoSLA，网页/API 使用 443，旧客户端 8443 保留；公开可信证书与域名专用严格 TLS 生效，访问无需 Vercel。
- 后台 app_url 指向 cloud.bingcn.site，引导池同步 API 与兼容域名，仍由服务端提供配置。
- 配置交换空间、资源和队列上限及代理回环监听；512MiB 初始 OOM 经调整重建修复，1GB 主机尚未完成生产容量验收。
- 公网 24 项、公网证书和直接源站 TLS 各 8 项、两入口真实订阅读取和浏览器注册页验证通过；未提交注册或交易。旧业务容器停止，回滚数据保留。详情见 SERVER_DEPLOYMENT.md。

## [Unreleased] - 邀请返利客户端 (2026-09-22)

- 账户页增加邀请返利入口，可读取并主动创建邀请码，复制网站注册链接与邀请码，显示邀请注册二维码。
- 展示 Xboard 注册人数、累计佣金、确认中佣金与可用佣金；币种由服务端提供，返利计算与结算保持在后台。
- 分享网站不可用时降级为邀请码；异常统计响应不展示为零；登录状态变化使页面数据失效。
- 补充七种语言资源以及邀请模型、接口、页面交互测试。
- 建立共享业务主线与独立平台验收路线；iOS 需要 Packet Tunnel/IAP，已有 iPhone，开发者团队待准备。
- 测试面板的网站地址配置为 `https://cloud.microsoftnexushub.top:8443`；App 实际读取配置、生成邀请链接与网页预填已验证，配置旧值已备份。
- 在测试面板精确镜像的无网络、只读临时容器中，通过真实 HTTP Kernel/业务服务/结算命令验证邀请归属与返佣；使用内存业务库和模拟付款完成状态，未产生真实交易。公网注册提交、下载引导、支付及并发结算仍需独立验收。
- 桌面收银使用系统浏览器，Android 控制器在重绘时复用，初始收银地址只接受 HTTPS；增加失败反馈及平台回归测试。
- 补齐 macOS Keychain entitlement，将 Podfile 与 Xcode 最低系统版本对齐当前 Xcode 27 SDK 的 macOS 12 要求，并更新 Pod 锁文件。
- 增加非发布的桌面构建验证脚本、Windows GitHub 标准 Runner 工作流与 PDEC；保留既有发版入口。
- 修复 Windows 首次 Flutter 初始化日志、批处理入口与短路径盘符根目录兼容问题，补齐 SQLite 等原生资产的安装目录复制，并固定 Flutter 平台生成文件为 LF 换行。
- macOS arm64 和 Windows x64 原生编译通过，分别保留 127/82 个包内文件的哈希清单；Windows 开发产物上传至 CI。正式签名、安装分发与 VPN 实机验收仍需完成。

## [Unreleased] - feature/m1-account-subscription (2026-09-08)

### 新增特性 (Features)
- **Xboard 商业版账号与订阅闭环**：
  - 支持内嵌式登录、注册、密码找回流程与 Auth Token 安全持久化（`SecureStore`）。
  - 支持套餐订阅信息自动同步与到期/流量监测。
  - 支持应用内商品列表（`Store`）、下单购买与历史订单查询。
- **高可用域名自动切换与救援**：
  - 引入 `DomainScheduler` 域名池健康探测与无感连接层故障轮换机制。
  - 支持远端引导源（`BootstrapClient`）更新入口域名池。
  - 支持订阅 Profile URL 主机名（Host/Port）热替换。
- **节点商业脱敏与地域智能包装**：
  - 实现 `NodePackager`：自动将节点清洗归入所属国家/地区分组。
  - 支持组内会话保持负载均衡 (`load-balance` with `sticky-sessions`) 或自动优选 (`url-test`)。
  - 首页支持商业版精简地域卡片与延时挡位聚合显示。
- **多语言适配**：
  - 补充 `en`, `zh_CN`, `zh_TC`, `ja`, `ko`, `ru`, `fa` 七种语言关于账号、订阅、订单及地域命名的国际化资源。

---

## [1.19.0+2026081601] - 2026-08-16
- 基于 Mihomo (Clash Meta) 内核的基础开源版。
- 多平台网络调试及规则分流客户端，支持 Android、macOS、Windows、Linux。
- 提供可视化设置、Widget 小组件、自定义主题与分流 UI 适配。
