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
- .agents/plans/2026-10-07-macos-proxy-transactions.md — macOS 系统代理事务核心、所有权恢复与原生接线验收
- SIGNING-POLICY.md — Windows 与 Android 发行签名边界和安全注入
- ios/README.md、core/iosbridge/README.md — iOS 原生通道、配置快照、内嵌核心与签名验收边界
- server/plugins/Fubei/README.md — 付呗支付适配契约与商户外部条件
- server/patches/billing/PLAN.md — 订单和返佣事务候选、隔离验证与部署回滚边界
- .pdec/contract.yaml、.pdec/README.md — 三端开发执行契约、授权来源、执行位置与回滚

- docs/validation/2026-10-07-three-platform/ — 平台候选公开脱敏构建回执
