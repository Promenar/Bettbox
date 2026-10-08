# Document Registry

## HLG

- governance-root: `.agents`
- handover: `.agents/handover.md`
- index: `.agents/handover-index.md`

## 核心文档（始终同步，不可跳过）

- docs/CHANGELOG.md — 版本变更记录
- docs/ARCHITECTURE.md — 架构全景与模块依赖
- AGENTS.md — 项目开发规范（治理声明）
- .agents/handover.md — 跨会话交接事实链（HLG 管理）

## 按需文档（项目有则列出，无则删除）

- docs/PRD.md — Bettbox 商业版（对接自建 Xboard 面板）产品需求与实现规格
- docs/bootstrap/domains.json — 当前服务端公开引导配置快照，Schema 见 PRD
- .agents/plans/2026-09-22-invite-and-platforms.md — 邀请实现范围、接口依据、测试边界与平台扩展路线
- .agents/plans/2026-09-22-shared-platform-validation.md — 共享分支、桌面收银与邀请集成验证实施计划
- docs/PLATFORM_VALIDATION.md — 平台能力、隔离业务验证、原生构建和 iOS 工程验收边界
- docs/SERVER_DEPLOYMENT.md — NoSLA 服务端、域名分工、Cloudflare 与迁移回滚
- docs/validation/2026-10-07-nosla/ — 服务迁移的脱敏数据、DNS、HTTP/TLS、订阅与浏览器证据
- .agents/plans/2026-10-07-nosla-migration.md — 迁移计划、独立审阅及切换条件
- .agents/plans/2026-10-08-supervisor-integration.md — macOS helper/host/Dart合同、背压与联合接线验收
- .agents/plans/2026-10-07-three-platform-release.md — 三端发行目标、关键路径、服务端边界与验收要求
- .agents/plans/2026-10-08-android-live-account.md — 独立开发验收账户、秘密边界与真实 Android 业务验收
- .agents/plans/2026-10-08-android-vpn-diagnosis.md — Android真实代理协议、TUN/JNI失败合同与设备验收计划
- .agents/plans/2026-10-07-macos-proxy-transactions.md — macOS 系统代理事务核心、所有权恢复与原生接线验收
- SIGNING-POLICY.md — Windows 与 Android 发行签名边界和安全注入
- ios/README.md、core/iosbridge/README.md — iOS 原生通道、配置快照、内嵌核心与签名验收边界
- server/plugins/Fubei/README.md — 付呗支付适配契约与商户外部条件
- server/patches/billing/PLAN.md — 订单和返佣事务候选、隔离验证与部署回滚边界
- .pdec/contract.yaml、.pdec/README.md — 三端开发执行契约、授权来源、执行位置与回滚

- docs/validation/2026-10-07-three-platform/ — 平台候选公开脱敏构建回执

- docs/validation/2026-10-07-three-platform/macos-runner-real-go-validation.json — Runner冻结Release构建、真实Go签名链与退出验证；完整应用另验

- docs/validation/2026-10-07-three-platform/macos-helper-bundle-validation.json — 生产helper封装、完整Release构建、嵌套开发签名和清单发布回归

- docs/validation/2026-10-07-three-platform/macos-flutter-supervisor-validation.json — 真实Flutter两代Session、32个公开child退出、完整App恢复及ad hoc entitlement拒绝边界

- docs/validation/2026-10-07-three-platform/macos-application-supervisor-validation.json — MacService传输接线、应用协调器/RPC实际Flutter与事件追踪负例；正常main/SC另验

- docs/validation/2026-10-07-three-platform/macos-preflight-recovery-validation.json — 未发行reservation的预检撤销证据、实际Session/Application重试及未知owner保留

- docs/validation/2026-10-07-three-platform/macos-sc-backend-validation.json — HTTP-only事务、SystemConfiguration SDK只读验收及stored字典恢复边界

- docs/validation/2026-10-07-three-platform/macos-protected-journal-validation.json — 受保护journal源摘要、实际红绿回归及验收边界

- docs/validation/2026-10-07-three-platform/android-release-build-attempt.json — Android正式APK实际构建失败阶段、网络固定事件及退出证明

- docs/validation/2026-10-07-three-platform/android-formal-apk-validation.json — 正式Android候选证书、产物/安装摘要、真实界面及未验收业务边界

- docs/validation/2026-10-07-three-platform/node-protocol-probe.json — 受限同源协议探测、源摘要、回归与真实失败边界

- docs/validation/2026-10-07-three-platform/upstream-subscription-status.json — 缓存过期与当前两种UA订阅HTTP失败、认证核对边界
- docs/validation/2026-10-07-three-platform/android-tun-control-flow-red.json — 生产启动控制流实际失败回归及替身边界

- docs/validation/2026-10-07-three-platform/native-fd-ownership-contract.json — 原生FD构造合同红绿回归、独立复审及未接线边界
- docs/validation/2026-10-07-three-platform/android-tun-abi-validation.json — 实际 Android ARM64 Go/JNI 编译链接、FD 输入清理回归及未覆盖设备边界

- .agents/plans/2026-10-08-macos-system-proxy-integration.md — 正常应用SC/endpoint授权、恢复次序及认证unknown待裁定设计
- docs/validation/2026-10-07-three-platform/android-jni-failure-validation.json — JNI helper与真实OnLoad九项函数表故障回归，非真实JVM
- docs/validation/2026-10-07-three-platform/android-vpn-lifecycle-validation.json — 生产协程门禁红绿、绑定/恢复/旧通知controller夹具与设备边界
- .agents/plans/2026-10-08-android-owner-integration.md — Android配置owner、typed完成回执、跨engine与资源收尾联合计划
- docs/validation/2026-10-07-three-platform/android-f881880-build-validation.json — f881880正式编译/验签/安装来源、冷启动、直连通路及上游未验收边界
- docs/validation/2026-10-07-three-platform/macos-sc-schema4-validation.json — schema4来源摘要、61项回归、独立回审与真实系统接线边界
- docs/validation/2026-10-07-three-platform/macos-session-recovery-gate-validation.json — Session恢复冲突/底层单次操作红绿、24+5项验证及正常应用接线边界
- docs/validation/2026-10-07-three-platform/macos-host-system-proxy-validation.json — Host恢复/启动授权接线、SDK编译及隔离夹具证据
- docs/validation/2026-10-07-three-platform/macos-empty-journal-validation.json — 真实SC锁权限、空记录恢复红绿及严格nil边界
- docs/validation/2026-10-07-three-platform/macos-host-late-sc-validation.json — 已投递SC完成乱序、保守恢复与独立复核

- docs/validation/2026-10-07-three-platform/macos-application-lifecycle-validation.json — Application配置与偏好状态回归、219项Flutter、静态分析及完整unsigned Runner构建边界

- .agents/plans/2026-10-08-macos-native-authorization.md — 系统认证参数、资源归属、取消和恢复验收合同
- docs/validation/2026-10-07-three-platform/macos-native-authorization-validation.json — 原生授权84项回归、宿主/完整构建和实际系统认证待验边界

- .agents/plans/2026-10-08-macos-development-signing.md — 唯一开发签名身份、证书Team来源与本机运行边界
- docs/validation/2026-10-07-three-platform/macos-development-signing-validation.json — 20项工具回归及真实开发签名候选；应用与发行验收另验

- docs/validation/2026-10-07-three-platform/core-listener-stop-action-validation.json — 生产handler/action检查式关闭的八场景红绿及core包回归

- docs/validation/2026-10-07-three-platform/core-config-prepare-validation.json — setup失败发布边界十三场景及实际Android Go/JNI编译证据

- docs/validation/2026-10-07-three-platform/android-owned-config-validation.json — 同步配置、严格回执、实际ARM64编译及JNI函数表证据与未接线边界

- docs/validation/2026-10-07-three-platform/android-start-report-validation.json — 生产State/Shutdown红绿、race、编译链接及TUN接线边界
- docs/validation/2026-10-07-three-platform/macos-profile-admission-validation.json — 真实候选启动拒绝分类、profile缺口和封装准入回归

- docs/validation/2026-10-07-three-platform/android-jni-checked-release-validation.json — 注册JNI释放完成状态、线程收尾红绿及实际ABI边界
