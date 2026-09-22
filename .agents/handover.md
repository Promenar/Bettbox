# 跨会话交接

<!-- hlg-schema: 1
write-position: eof
history-policy: append-only
timestamp-semantics: record-write-time
index-generated: true
recovery-order: index -> query -> rg fallback -> full record
-->

> 本文件由 HLG 管理。新记录只能追加到文件末尾；不得编辑、删除、重排、压缩或插入既有历史记录。
> 标题时间戳表示记录写入时间；事件发生时间应使用独立结构化字段。
> `handover-index.md` 是可重建导航，不是事实源；恢复顺序为 index → query → rg 兜底 → 相关记录原文。

## 2026-09-09T01:40:44+08:00 · 治理体系重建：启用 .agents HLG，旧 .agent 体系作废

type: maintenance
scope: ["project"]
status: done
tags: ["governance", "migration", "hlg-bootstrap"]
continuity: resume
continuity-key: hlg-governance
record-fingerprint: 966dad4ed525176a2b34648645c82d803fe375034b7145480e3bb103a794afd6

### Summary
按用户指示重建本项目治理体系：旧 `.agent/`（handover.md、registry.md，由其它客户端在 2026-09-08 生成，未纳入 git 跟踪）被判定为错误产物并作废，整体备份至 /tmp/bettbox-legacy-agent-20260909-013946 后可回滚。以 HLG 标准 `.agents/` 为新治理根：bootstrap 生成 registry.md（登记 governance-root=.agents）、handover.md（自带 append-only 自保护门禁）、handover-index.md；创建 handover-archive/、tmp-agent-reports/、plans/ 约定目录。AGENTS.md 中文档治理声明已覆盖为 .agents 体系。旧 handover 中的 M1 业务事实与 docs/CHANGELOG.md [Unreleased] 记录一致，无独有信息，故不并入新事实链。

### Changed
治理根目录 .agent → .agents；AGENTS.md 文档治理与非微小变更章节由 .agent/ 改为 .agents/；项目内旧治理文件移出（备份于 /tmp/bettbox-legacy-agent-20260909-013946）。

### Validation
bootstrap applied: true（create registry/handover/index 三项）；.agents/ 目录结构确认存在 registry.md、handover.md、handover-index.md、handover-archive/、tmp-agent-reports/、plans/；项目内已无 .agent 与 .agents 并存。

### Next
后续跨会话写入一律经 HLG append 追加到 .agents/handover.md；需接续 M1 账号订阅工作（工作树存在并行会话 F-NODE-7 未提交改动）。

### Risks
.gitignore 使用 *.md + 白名单策略，.agents/ 下治理文件当前被 git 忽略，无法纳入版本管理（如需入库须由用户决定加白名单）；旧 .agent 内容未并入新事实链（由 CHANGELOG 与代码覆盖）。

### DIA
治理根变更已同步：AGENTS.md 治理声明覆盖、.agents/registry.md 登记；docs/CHANGELOG.md、docs/ARCHITECTURE.md 无 .agent 路径引用，无需修改。

### HLG
HLG bootstrap 完成；本记录为 .agents/handover.md 事实链第一条（迁移审计）。

## 2026-09-09T01:45:22+08:00 · HLG 治理文件纳入 git 跟踪（.gitignore 白名单 + 提交 96ffc4b）

type: maintenance
scope: ["project"]
status: done
tags: ["governance", "git", "hlg-bootstrap"]
continuity: resume
continuity-key: hlg-governance
record-fingerprint: 64cde8a8a246668a9967a25f37f226f0691c989a4f762d371efc27264def769a

### Summary
按用户要求「HLG 必须完整跟随 Git 同步」：原 .gitignore 的 `*.md` 全局忽略使 .agents/ 治理文件与 AGENTS.md 无法入库。已在 .gitignore 末尾追加白名单（!AGENTS.md、!.agents/、!.agents/*.md、!.agents/**/*.md），恢复跟踪后提交 commit 96ffc4b（5 文件，144 insertions）：.agents/handover.md、.agents/handover-index.md、.agents/registry.md、AGENTS.md（v2.0）、.gitignore。

### Changed
.gitignore 增加 HLG 白名单；AGENTS.md 与 .agents/ 治理文件纳入 git 跟踪；治理体系可随 clone/checkout 完整恢复。

### Validation
git check-ignore 确认 AGENTS.md 与 .agents/*.md 最后匹配白名单规则；git status 显示为未跟踪可提交状态；暂存区核对仅本任务 5 文件（无并行会话源码混入）；commit 96ffc4b 成功。

### Next
远端同步（push）未执行，是否推送由用户决定；后续治理记录经 HLG append 后需随同提交（handover-index 为派生文件会随 append 变化）。

### Risks
提交未推送远端；.agents/**/*.md 白名单同时覆盖未来 handover-archive/、tmp-agent-reports/、plans/ 下的 md（符合完整同步意图）；空目录不入库属 git 正常行为。

### DIA
.gitignore 白名单变更与 AGENTS.md v2.0 入库已同步；registry.md 记录在 .agents/registry.md 中。

### HLG
本记录为 .agents/handover.md 事实链第二条（git 同步审计），append 后需一并提交。

## 2026-09-22T10:15:59+08:00 · 邀请返利客户端候选与平台扩展路线

type: implementation
scope: ["Bettbox", "xboard", "platforms"]
status: done
tags: ["invite", "commission", "ios", "macos", "windows", "candidate"]
continuity: waiting
continuity-key: bettbox-invite-platforms
record-fingerprint: 4299f4386f10fb51684b46352a4c6e0b5e86fe938f3a7cb212878a1718e60914

### Summary
用户确认沿用 Xboard 后台返利规则，客户端提供邀请二维码、网页注册链接和收益统计；新用户在网页注册绑定后由网站引导下载。邀请客户端实现已通过本地验证，平台扩展完成源码盘点和实施路线，真实部署闭环待验收。

### Changed
新增 lib/xboard/invite.dart 与 lib/views/account/invite_page.dart，账户页接入入口，复用 Material 3 和 qr_flutter；扩展邀请端点与模块导出，更新七种 ARB 及生成资源，补充 19 项邀请测试。收益读取后台四项统计，创建邀请码仅主动触发，连接超时后只读刷新，不重放创建；app_url 提供 HTTPS 分享站点，账户切换丢弃旧数据，小数分展示保留精度。同步 PRD、ARCHITECTURE、CHANGELOG、registry、实施计划；为既有核心架构/变更文档增加精确 Git 白名单。

### Validation
Flutter 3.44.9 / Dart 3.12.2 既有工具链；flutter test --no-pub 91 项全部通过；针对新增和接入的 7 个 Dart 文件 analyze 无问题；git diff --check 无输出；新增 19 项文案七语言一致，intl_utils 成功。Widget 验证 320px+1.6 倍字号、复制/QR 一致、重复创建防护、超时只读刷新、缓存及异步回包账户隔离。页面测试图经 macOS Vision 解码出预期邀请链接。原生 Sol medium 独立只读审阅，修正小数分展示后无剩余 P0/P1/P2 发现；主控核对代码和真实测试日志。

### Next
提供当前公开注册网站地址并恢复测试面板后，核对部署版接口、app_url 和主题路由，使用受控测试环境验证网页预填/注册归属/下载引导/返佣状态。桌面端先验证现有 macOS/Windows 商业链路，iOS 先构建独立 Packet Tunnel 最小真机样机，再接已决 IAP 及服务端幂等账务；具体文件和验收见 .agents/plans/2026-09-22-invite-and-platforms.md。

### Risks
内置面板公开配置与首页返回 HTTP 错误；上游 cedar2025/Xboard@4f48e61a2cbc6db5338872b6bdb45ef954ec1256 的源码契约不能替代部署联调。未调用真实注册、生成邀请码、付款、提现或后台变更；未执行平台安装包构建、设备 VPN 验收或发布。iOS 缺 Runner/隧道工程，现有非 Android 内核分支属于桌面启动方式；.pdec 契约缺失，跨平台执行与无发布构建入口尚需适配。首期不含系统分享面板或二维码图片导出。

### DIA
已同步 docs/PRD.md、docs/ARCHITECTURE.md、docs/CHANGELOG.md、.agents/registry.md 和实施计划；AGENTS.md 的现行约束无需修改。

### HLG
使用 HLG append 先 dry-run 后 apply 追加此记录并重建索引。邀请部署验收及平台扩展以 bettbox-invite-platforms 工作流接续。

## 2026-09-22T10:26:36+08:00 · 测试面板可达性与邀请站点配置核验

type: diagnosis
scope: ["Bettbox", "xboard"]
status: done
tags: ["invite", "panel", "connectivity", "configuration"]
continuity: waiting
continuity-key: bettbox-invite-platforms
record-fingerprint: 25883c8068b8a55404d923dcda62104823b0102254a355e2384d1ef1f05492b7

### Summary
用户确认测试面板为 https://cloud.microsoftnexushub.top:8443/，源站 IP 170.106.143.23。已验证入口可用与邀请注册页预填；当前邀请链接指向不可达的后台 app_url，需明确授权后更正该持久配置。

### Changed
仅同步 .agents/plans/2026-09-22-invite-and-platforms.md 的当前联调状态；客户端源代码、后台配置和业务数据均未修改。

### Validation
curl 经普通域名、noproxy 直连、resolve 指定源站三条路径请求首页和 /api/v1/guest/comm/config 均 HTTP 200，TLS 校验为 0。Python 默认 User-Agent 请求公开配置返回 403，curl 标识返回 200；以项目实际 XboardApiClient/Dio 请求成功。浏览器 /#/register?code=BETTBOX_QA_ONLY 将测试标记预填到禁用邀请码字段，未提交表单。部署主题 JS 含已核对的 invite/fetch、invite/save、user/comm/config 与同源注册分享路由；主题 SHA256=69ff1e68dd44b84f803e631367b6fc9dfd52e79d049067fa52cfa859031f20dc。公开 app_url 为 https://cloud.bingcn.site，该域名 curl TLS 失败且浏览器 ERR_CONNECTION_CLOSED。

### Next
拟将测试面板 app_url 从 https://cloud.bingcn.site 更正为 https://cloud.microsoftnexushub.top:8443；需用户明确授权服务端持久配置变更。取得授权与安全的管理访问后，只更新该项并验证公开配置、客户端生成链接与网页路由。随后使用受控测试账号核验登录态邀请统计、注册归属与返佣流程。

### Risks
已复现请求客户端标识造成的结果差异，但服务端具体拦截规则未查证，不能称服务宕机或断言具体 WAF 配置。网页预填不证明邀请码有效或注册已绑定；未登录、未创建邀请、未注册、未触发真实付款或结算。dart run 触发既有 objective_c 缓存 kernel 版本不匹配，改用同一 Dart SDK 直接运行无原生依赖的 API 探针成功；未清理缓存或改工具链。

### DIA
已同步实施计划的联调事实；产品行为、接口设计和架构无变化，PRD/ARCHITECTURE/CHANGELOG 无需修改。

### HLG
通过 append dry-run 后 apply 追加核验与勘误，保留前序事实链；后台配置更正与业务验收维持 waiting。

## 2026-09-22T14:09:33+08:00 · 测试面板 app_url 配置调整与邀请入口验证

type: maintenance
scope: ["Bettbox", "xboard", "test-panel"]
status: done
tags: ["invite", "configuration", "authorization", "rollback"]
continuity: waiting
continuity-key: bettbox-invite-platforms
record-fingerprint: a24772e96d8db69b0ba22dc0966b4d85fbb51cdb1835c1e22bd0077db294d3ab

### Summary
用户明确允许将测试面板 app_url 调整为 https://cloud.microsoftnexushub.top:8443，并授权开发阶段可配置项按需调整。该项已生效，App 实际数据访问及链接构造代码与浏览器邀请码预填均验证通过；不将此阶段授权扩大为真实交易、凭据/权限变更或生产发布授权。

### Changed
经现有 SSH 认证管理 170.106.143.23 的 /opt/xboard-test 服务，容器 xboard-test-xboard-1 对应上游 SHA 4f48e61a2cbc6db5338872b6bdb45ef954ec1256。通过 Xboard 原生 admin_setting 接口，在事务内仅将 app_url 从 https://cloud.bingcn.site 更新为 https://cloud.microsoftnexushub.top:8443；其他设置的前后 SHA256 一致。随后 php artisan octane:reload 重载 Web 工作进程。客户端代码与依赖无变更。

### Validation
域名入口及 --resolve 指向源站 IP 的 guest/comm/config 均返回 success 与新 app_url；本地同一 Dart SDK 直接运行项目 XboardApiClient 和 buildXboardInviteLink，生成 https://cloud.microsoftnexushub.top:8443/#/register?code=BETTBOX_QA_ONLY，断言通过。Codex 浏览器注册页邀请码字段正确预填该测试标记，未提交注册。Setting 支持类与 helper 在容器和本地源码 SHA256 一致。回滚记录 286 字节，持久备份权限 600；git diff --check 通过。源码未修改，未重复运行此前已通过的 91 项测试。

### Next
使用受控测试账号核验登录态邀请码/佣金接口，以及网页真实注册归属与返佣状态。macOS/Windows 商业链路与 iOS 最小真机隧道继续按实施计划推进。开发阶段与本任务相关的可配置项可在既有授权内按需调整，保留范围、验证和回滚记录。

### Risks
只有公开配置、生产链接构造与网页预填完成真实验证；未创建真实邀请码、未注册账户、未产生付款或佣金流水，不能认定返佣到账闭环已验收。回滚数据位于服务器 /opt/xboard-test/config-backups/app-url-20260922T060534Z.json，旧值为 https://cloud.bingcn.site；需要回滚时经相同 admin_setting 接口恢复该单项并重载 Octane。未向模型或日志输出登录密码、私钥、Cookie 或令牌。

### DIA
已同步 docs/CHANGELOG.md 和 .agents/plans/2026-09-22-invite-and-platforms.md 的测试面板配置、验证及回滚状态；PRD、架构、registry 的行为约定未变化。

### HLG
经 append dry-run 后 apply 追加配置操作与会话授权事实，并重建索引；bettbox-invite-platforms 后续为测试账号业务验收和平台开发。
