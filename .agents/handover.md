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

## 2026-09-22T17:51:51+08:00 · 邀请集成验证与桌面候选构建进展

type: maintenance
scope: ["Bettbox", "xboard", "platforms"]
status: in-progress
tags: ["invite", "macos", "windows", "ios", "validation"]
continuity: resume
continuity-key: bettbox-invite-platforms
record-fingerprint: fcb4b5ed0de853ad637a36899efc29b2b5c4f9088e20e97827f7565f71c120b3

### Summary
邀请客户端共享逻辑与桌面收银适配已完成，沿用单仓库业务主线。用户有 iPhone、Apple Developer 团队尚未准备好。macOS 已通过关闭 Xcode 签名的原生编译及包内核心哈希验收；Windows 首次 CI 原生构建仍在执行。

### Changed
候选提交依次为 aa4b6c3、fe121ca、9a59d0d、7e0d08b。增加 Android WebView 控制器复用、桌面系统浏览器收银、HTTPS 地址校验、7 语言错误反馈、macOS Keychain capability、macOS 12 工程/Pod 基线及桌面验证入口。新增受限 Windows GitHub Runner workflow、PDEC 与安全的 Xboard 内存验证工具。本任务开发配置与持续推进授权作为限定桌面开发操作依据，不扩展到生产发布或真实资金变更。

### Validation
Flutter 全量 99 项通过；相关 3 文件 analyze clean；当前 Python 15 项通过。真实 Xboard 镜像在无网络、只读根/源卷、256 MiB/1 CPU 临时容器中完成 32 个检查，HTTP Kernel 注册绑定、100 元订单按 10% 算出 1000 分佣金、结算统计 [1,0,1000,10,0]→[1,1000,0,10,1000]、顺序重跑不重复；付款完成状态为夹具，不调用真实支付。macOS 9a59d0d clean 源码编译 App 169.3 MB，127 个文件进入 manifest，core SHA c1ecc1d0a92cb7dabb0e8baf6deb8388830914bea88d7a72945d37cdef02b912 与 bundle Contents/MacOS/BettboxCore 一致，源码/锁无漂移。署名事实为 linker ad hoc、无 Team、无资源封印，不能视为开发者签名安装包。

### Next
等待并核对 Windows run 35712369349（7e0d08b21770d9410dad17fa370ff883428a76bc，https://github.com/Promenar/Bettbox/actions/runs/35712369349）的真实构建、core/helper 绑定与 artifact；失败则修复并验证新候选。完成最终 DIA/HLG 文档提交。iOS 仍需 Runner、Packet Tunnel 桥接、App Group/Keychain、IAP 与团队真机验证；不只是签名就绪即可上线。

### Risks
macOS Keychain capability 经真实 Xcode 检查要求开发证书；未签名路线只用于编译。Apple 本机工具为 Xcode 27.0、Go 1.26.5、CocoaPods 1.17.0/Ruby 4.0.7，安装 CocoaPods 同时安装/更新其 OpenSSL 3.6.4 依赖。Windows 已修复 YAML 单行冒号、Python cp1252 输出和 Flutter/Dart .bat CreateProcess 查找问题，尚待原生构建最终结果。服务端 CheckCommission 缺少并发幂等保护，未改真实后端账务。公网真实注册、邮件收件、下载引导、付款/提现、各端系统权限及 VPN 设备体验均未验收。

### DIA
已同步 README、PRD、ARCHITECTURE、CHANGELOG、PLATFORM_VALIDATION、registry、PDEC 与实施计划；脱敏服务验证和 macOS 构建报告已随候选提交。

### HLG
阶段事实通过 append dry-run/apply 保存；Windows 最终结果待追加，continuity 保持 resume。

## 2026-09-22T18:46:18+08:00 · 桌面原生构建验收与阶段暂停

type: maintenance
scope: ["Bettbox", "xboard", "platforms"]
status: done
tags: ["invite", "windows", "macos", "ios", "validation", "pause"]
continuity: waiting
continuity-key: bettbox-invite-platforms
record-fingerprint: 6843946713b6e62652f6797c30e0f62812c8c0f2fb76aa87f3c38918143463d9

### Summary
邀请返利与桌面工程验证阶段已收口。Windows x64 和 macOS arm64 均完成原生编译及包内文件哈希验证，邀请后端隔离业务验证已通过。用户要求“这阶段动作完成后暂停”，因此只完成当前候选验收、文档交接及提交同步，随后暂停后续开发；iOS 原生工程与设备验收未启动。

### Changed
候选 601fba7 修复 Flutter 首次启动日志与版本 JSON 混合输出；804f327 保留原生失败诊断；7ebadef 将仓库从 S:\ 盘符根调整为 S:\s，避免 PROJECT_DIR 末尾反斜杠与 FLUTTER_TARGET 拼接，并按锁定 Flutter 3.44.9 模板补上 native_assets/windows 安装规则；dd2998859b23f6fac9245077ebcd842e1e424d2a 为 7 个生成文件固定 LF。前一候选已编译成功但被源码漂移检查拒绝，诊断确认仅 CRLF/LF 差异，无注册代码差异。源码和锁文件检查未被绕过。PDEC 已更新引用摘要并通过执行校验。

### Validation
Windows run 35716722203（https://github.com/Promenar/Bettbox/actions/runs/35716722203）在 dd2998859b23f6fac9245077ebcd842e1e424d2a 上整体 success：Go core、Rust helper、Flutter App 编译成功，源码/锁文件无漂移，82 个 bundle 文件进入清单，含 sqlite3.dll，core/helper 源与包内哈希一致。主控下载 artifact 后逐一复核 82 个文件大小与 SHA256，并解析 Bettbox.exe、BettboxCore.exe、BettboxHelperService.exe、sqlite3.dll 的 PE Machine=0x8664。Windows 证据已保存 docs/validation/2026-09-22-windows-x64.json。本地 Python 16 项通过；客户端源码与之前 99 项 Flutter 回归通过的版本未变。macOS 9a59d0d 的客户端/Go/macOS 源码与当前候选相同，本机 127 个 bundle 文件复核全部匹配证据。原生独立审阅者 invite_review 对构建脚本失败收口、签名事实、短路径和 native assets 规则未发现新的 P0/P1/P2，主控补齐其提出的 CI、生成文件差异和 DLL 实物验收缺口。

### Next
按用户明确要求暂停，不开展新的平台实现、CI 重跑、设备联调或发布。恢复后先读取本条交接与 docs/PLATFORM_VALIDATION.md：按适当签名在 Windows/macOS 验证登录持久化、邀请实际扫码、系统浏览器、代理/TUN、服务和休眠恢复；准备可分发安装包及网页下载入口；iOS 需要 Runner、Packet Tunnel 桥接、App Group/Keychain、IAP 与开发者团队签名。用户有 iPhone，开发者团队尚未准备好。

### Risks
编译通过不等于 VPN、系统权限或设备体验验收；macOS 产物是请求禁用 Xcode 签名后的链接器 ad hoc，无 Team/资源封印。Windows artifact 保留 7 天，非正式发布。测试面板 android_download_url、windows_download_url、macos_download_url 均为空，公网注册提交、真实邮件、下载引导、付款和提现仍未验收。勘误：前条 HLG“CheckCommission 缺少并发幂等保护”表述过宽；实际正常调度有 onOneServer() 与 withoutOverlapping(5)，当前没有正常调度重复返佣证据。单笔查询缺少数据库行锁及相应唯一约束，直接并发调用或调度锁失效时的数据库幂等未验证。隔离测试只证明顺序重跑不重复入账，没有修改真实账务。

### DIA
已同步 PLATFORM_VALIDATION、CHANGELOG、PDEC README、平台实施计划和 Windows 构建证据；README、ARCHITECTURE、PRD 与 registry 已复核，共享架构和业务约定无新增变化。

### HLG
使用 append dry-run/apply 追加最终构建证据、前序并发风险勘误与用户暂停边界，重建索引；continuity=waiting，等待用户恢复指令。

## 2026-10-07T17:56:04+08:00 · Xboard 全量迁移至 NoSLA 与 Cloudflare 域名切换

type: maintenance
scope: ["Bettbox", "xboard", "server", "cloudflare"]
status: done
tags: ["migration", "nosla", "dns", "tls", "backup", "validation"]
continuity: none
record-fingerprint: 92845fea2386f66c9fe63bf62b3cb4f5036016be6030481484c72e5185b0e458

### Summary
按用户明确授权将 Xboard、SQLite/Redis、CloudBridgeRelay、主题补丁、Caddy 与订阅辅助 Mihomo 从腾讯云170.106.143.23迁至 NoSLA216.23.116.56。四条相关 A 记录切换完成，业务入口无需 Vercel；客户端平台开发保持原暂停边界。

### Changed
在 NoSLA 安装官方 Docker/Compose及2GiB swap，导入源确切镜像。源业务冻结后传输最终归档并比对 SHA256；app_url改为https://cloud.bingcn.site，引导池包含API与兼容域名；Caddy公开可信证书覆盖443/8443，CF仅相关主机名使用严格TLS。Xboard最终768MiB/CPU1，三类Horizon队列上限1；代理端口仅回环。源Xboard/Mihomo停止且restart=no，旧Caddy可信8443仅转发新主机，保留回滚备份与已通过caddy validate的回滚模板。官方cf CLI和本机cf-xboard入口配置完成，复用SSH临时加载既有DNS令牌，未新增OAuth授权。

### Validation
34张表内容及35个绑定资源启动前摘要全部一致；4用户、2套餐、2订单、133节点保留，运行后仅app_url设置发生预期差异，SQLite integrity_check=ok。Redis RDB恢复325未过期key、保存ok；Horizon运行，最终3容器OOM=false/restart=0。24公网网页/API/引导请求200，源站独立8项TLS从腾讯云固定目标IP/SNI验证全部可信；两入口既有账户真实订阅200且含proxies。4并发12API请求全200，中位0.5805秒、最大1.057秒。浏览器注册页显示邮箱/密码/邀请码。主控复核独立审阅建议，纠正边缘/源站证书证据口径、Redis回滚保存顺序、固定上游/SNI/Host和旧证书续期边界；独立复核无新增阻断。证据存于docs/validation/2026-10-07-nosla。

### Next
保留旧主机与备份用于回滚；过渡转发在观察期确认后另行退役。新平台注册、签名、安装包、VPN及发布不在本迁移范围，保持用户原暂停要求。

### Risks
NoSLA物理内存929MiB且已使用swap；512MiB初始启动曾OOM/超时，调整重建后恢复。未完成生产容量验收或完整回滚演练；回滚不能仅恢复DNS，源443仍由其他项目占用，须最新数据回传+可信8443源站+相关CF Origin Rules。旧复制证书有效至2027-01-05且不自动续期，回滚当天需复验。API备用与主站同主机，没有主机级高可用。没有提交注册、真实付款/邮件/提现或设备VPN。

### DIA
已同步README、ARCHITECTURE、CHANGELOG、PRD历史部署指向、SERVER_DEPLOYMENT、bootstrap配置快照、registry、实施计划和脱敏验收证据；没有修改客户端代码。

### HLG
通过append dry-run/apply追加迁移事实与验收边界并重建索引；原邀请平台工作流的waiting/暂停记录保持不变。

## 2026-10-07T18:27:59+08:00 · 本机开发分工与 iOS 模拟器环境就绪

type: maintenance
scope: ["Bettbox", "platforms", "environment"]
status: done
tags: ["android", "ios", "macos", "environment", "validation"]
continuity: none
record-fingerprint: b2e9dc0551b74b82144dc99bc494105fa8be13908ad09689663d89552c43180b

### Summary
用户确定本机负责 Android、iOS、macOS 开发调试，Windows 原生调试在 Windows 环境完成。授权体积合理时安装 iOS 运行时；已完成官方安装及设备启动验证。

### Changed
通过 xcodebuild -downloadPlatform iOS -architectureVariant arm64 安装 iOS 27.0（24A434）。下载约8.05GB，运行时 AssetData 实测约7.5GiB。Xcode 自动生成机型配置，共用同一运行时；没有额外手工创建 iOS 或 Android 设备，也未删除任何既有设备。更新 PLATFORM_VALIDATION 与 CHANGELOG。

### Validation
安装命令退出0，simctl runtime list 显示 Ready、arm64、sizeBytes=8067000161。现有自动生成 iPhone17 经 simctl bootstatus -b 启动完成，Flutter devices --machine 识别 isSupported=true、targetPlatform=ios、emulator=true。随后定向 shutdown 验证设备。Android 3个AVD均ARM64；Nexara文档明确引用API31/API35/Pixel7兼容和性能测试，Pixel7当前镜像API36.1；日常无需按项目各建AVD。工作树仅任务文档/交接变更，用户.video_agent保留。

### Next
日常共用一个Android模拟器与一个iPhone模拟器，兼容性回归时切换版本。正式Android/iOS构建与联调前登记并核验PDEC入口。本轮仅环境准备，不自动启动既有暂停的平台实现或支付联调。

### Risks
模拟器安装和启动不等于Bettbox iOS支持；仓库仍无ios主工程，Packet Tunnel、内核桥接、项目签名、IAP和真机VPN待开发验收。当前Apple Development身份存在，不代表团队及项目权限已具备。未修改shell PATH、资金或支付凭据。

### DIA
已同步PLATFORM_VALIDATION和CHANGELOG，架构与客户端代码无变更，既有PDEC构建字段保持原状。

### HLG
按append dry-run/apply新增环境事实与本机分工，不回写暂停记录，平台业务验收不外推。

## 2026-10-07T18:48:52+08:00 · 三端发行目标启动与共享网络安全基础验收

type: development
scope: ["Bettbox"]
status: in_progress
tags: ["release", "android", "ios", "macos", "xboard"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 3d6b632ca91ac2190c24cb20470144de963d0d3093bc27379a4658039121af80

### Summary
用户明确建立自主三端开发与服务端适配 Goal，交付目标为实际可用发行版；当前 Goal active，未完成发行。共享网络安全基础完成独立审阅与回归。

### Changed
实施HTTPS地址策略、域名池更新、禁止API/引导自动重定向、非成功HTTP状态优先判定及凭据日志脱敏；Android缺签名和缺内核输入时中止。计划见 .agents/plans/2026-10-07-three-platform-release.md。原生iOS与付呗候选由有界Agent施工，尚未作为发行交付。

### Validation
Flutter全量106项测试通过、另4项实际IO重定向回归通过；flutter analyze无问题。macOS应用169.3MB编译成功，锁文件无漂移，但构建期间仓库并行变更导致source_unchanged=false，入口非零退出，不作为发行证据。GUI实际启动、未登录首页/账户/登录页和NoSLA套餐读取通过。iOS基础bridge race通过，但独立审阅随后发现Close竞态、modulemap和来源记录不足并要求修复；集成版本仍待重新验收。Android脚本10项和契约扩展3项Python测试通过，预检通过，真实Android构建未开始。

### Next
稳定源码后更新PDEC证据并重新验证iOS集成、Android门禁和原生构建；接入Runner/PacketTunnel、真实账户订阅邀请、数据库到账返佣幂等与服务端适配；完成签名与设备发行验收。

### Risks
有效Apple开发签名身份不等于具备NetworkExtension团队权限，真机连接与团队状态待答复。付呗默认禁用，商户门店产品权限及安全秘密引用未确认；回调/精确金额修复待隔离PHP验证，数据库并发幂等未实现。PDEC统一枚举暂不包含Android，项目扩展保留真实Android目标并独立验证。用户.video_agent未纳入任务。

### DIA
已同步 CHANGELOG 和 ARCHITECTURE 的共享安全变更；原生与服务端文档待对应工作包验收后同步。

### HLG
结构化追加本记录，Goal保持active，继续自主推进。

## 2026-10-07T19:31:21+08:00 · 三端原生核心验收与服务端候选来源核验

type: development
scope: ["Bettbox"]
status: in_progress
tags: ["release", "ios", "android", "billing", "validation"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: a33080106f2dc07ac98704c4abaeb0c6ccf7d6bc1eb1f7874b8979c8e941125c

### Summary
Goal保持active，未交付可用发行版。原生核心、实际SDK类型检查及候选审阅推进；正式签名、真机和真实支付验收未完成。

### Changed
生成ios Runner与PacketTunnel原生工程、共享配置快照和内嵌Mihomo C ABI。主控修复停止回调独立截止时间、完整资源集合校验、实际复制预算和控制消息门禁，补原生测试。Android构建使用独立Gradle目录与归属核验；服务端付呗和SQLite计费候选经独立审阅，按线上订单源码重基。用户.video_agent不纳入任务。

### Validation
iOS完整核心设备/模拟器arm64 XCFramework v2构建成功，Clang/Swift模块导入通过，集成Go race测试通过。Shared3+PacketTunnel真实Simulator SDK Swift类型检查通过，C.char桥类型修复；Runner及新增原生测试未执行。主控Android构建脚本22项测试通过，真实构建核心完成但Gradle插件解析失败，锁文件和来源无漂移、任务进程清理核实；未生成APK。早期付呗117项真实隔离PHP fixture通过，但最新ledger接线及重基候选不复用该证据。

### Next
冻结Dart iOS接入后独立审阅、全量Flutter回归、Runner/扩展编译与原生测试；服务端重基并修apply提交后故障回滚和outbox失败公平退避，再运行隔离SQLite与实际Laravel路径；稳定Mac候选重建并完成登录/VPN；完成发行签名与下载入口。

### Risks
Android DNS 100.100.100.100对两个Gradle域名A查询返回RPZ NXDOMAIN；公开DNS原域名TLS制品200仅只读诊断，任务级解析绕过待用户答复，未修改DNS。正式Android keystore、Apple团队及真机连接、商户门店权限与安全秘密引用待答复。线上3个订单源码与本地来源hash不符，已取得安全扫描后的公开差异，不能跳过hash应用旧候选。付呗保持禁用，无生产迁移或资金操作。

### DIA
已同步PLATFORM_VALIDATION、ARCHITECTURE、iOS README、PDEC README和registry；ios/Vendor二进制不提交。服务端候选文档持续随重基同步。

### HLG
使用append dry-run/apply记录可恢复事实。未改写既有记录；Goal持续推进，外部条件不伪装验收通过。

## 2026-10-07T20:47:13+08:00 · 正式 Android 签名创建、iOS 模拟器应用与 Laravel 集成验收

type: development
scope: ["Bettbox"]
status: in_progress
tags: ["release", "android", "ios", "billing", "validation"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: e9f002ab11536a8ea6b8c16ab5c6f01de1fde41a7d3236869082927757fce881

### Summary
用户授权无既有发行密钥，正式 Android PKCS12 密钥已实际创建，密码安全注入登录钥匙串，未生成正式 APK。iOS 完整 arm64 模拟器应用编译、安装、启动及未登录首页到登录、注册导航通过。真实 Laravel 隔离集成通过。

### Changed
Android 密钥目录0700、文件0600，公开证书SHA256为6a121d74f9159b27e4b44255db8f85a9cb8d59ae052e93ba7646666d8a044a82；签名环境模块读取安全存储并校验身份，11项测试通过。iOS Pods最低15、SDK libresolv链接、arm64模拟器排除x86_64及Extension嵌入阶段修复。Laravel夹具使用真实Kernel及服务，隔离空库和精确镜像。

### Validation
共享Flutter135项测试通过，analyze无问题。ios-simulator-build.json passed且source_unchanged=true，VPN及发行签名未验证。billing-laravel-receipt-05ab3a3ac465496d8707db25074f0c94.json passed、source_unchanged=true、cleanup_verified=true；认证/插件发现/网关网络为显式夹具。Android实际官方JavaTLS通过，但Gradle help阶段DNS租约到期失败，源码及锁文件未变、owned进程清理通过。

### Next
修复Android任务连接方法：仅loopback透明HTTPS CONNECT代理，严格9官方域名443，原TLS证书校验、原TTL、bounded owned进程/socket/thread，纯测试及独立审阅后更新PDEC再实际网络/构建。完成原生XCTest、macOS稳定构建与设备业务验证。

### Risks
无Android APK或三端发行包；无Apple团队/真机VPN证据，无真实付呗付款或生产交易改造。历史macOS候选构建来源漂移，不作为发行验收。任务代理仅临时构建传输，禁止系统DNS/全局代理/新源。密钥不可丢失，备份及正式签名APK待验收。

### DIA
已同步PLATFORM_VALIDATION、CHANGELOG、SIGNING-POLICY及iOS说明；任务连接改造文档待实现验收后同步。

### HLG
结构化append先dry-run再apply；本记录保留当前实测来源及后续，不将候选标为正式发行。

## 2026-10-07T21:17:45+08:00 · iOS原生七项通过与Android Gradle启动参数定位

type: development
scope: ["Bettbox"]
status: in_progress
tags: ["ios", "android", "macos", "validation", "release"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 1f0b34dccb456f2134f6d1c61d0ac2adcb2a68b7ef919af8762cc4bfe6de5776

### Summary
iOS原生RunnerTests七项实际通过，51个原生输入文件哈希未变；模拟器登录/注册导航及空表单提示已验证。Android任务CONNECT实际官方TLS与224116304字节Gradle8.14完整发行包下载成功，help在实际JVM缓存门禁失败，无APK。

### Changed
修正原生测试使用SDK的destinationNetworkPrefixLength字段和Data读取try。桌面来源冻结增加未跟踪字节、POSIX目录句柄及Windowsreparse检查，19项测试通过且独立审阅闭合静态P2。任务代理HTTP绕过P2已修、55项测试及独立复审通过；安全Gradle诊断和JVM早注入正在实现。

### Validation
ios-native-tests-r2.xcresult实际passed7/failed0/skipped0，ios-native-tests.json与ios-native-source-r2.json保存事实。Androidreceipt failed phase gradle-help/source_unchanged与locks_unchanged为true，proxy及Gradle清理验证成功，六条默认TLS探测通过，含MavenTTL11/GithubTTL13的新连接。NoSLA三容器运行、Xboard约337MiB/768MiB，Dart/浏览器UA公开配置HTTP200。

### Next
任务受控JAVA_TOOL_OPTIONS仅由公开flags生成，启动时设置DNS闭包/security单等号追加及proxy，不继承用户旧值；实际Gradle与Java需逐九个官方host证明directDNS被拒绝，再独立复审/PDEC登记/网络help。门禁通过后接正式签名、发行APK、设备安装。macOS权限/代理与iOS IAP须独立施工验收。

### Risks
Gradle8.14公开源码将java.security.properties及jdk.net.hosts.file视为mutable，在build阶段才设置；实际缓存guard失败支持启动时点不足，但尚未确认具体哪个缓存项失败。当前Mac候选core为用户755无setuid，发行代码现有整体core提权与IPC缺鉴权、代理所有权恢复及假启动显示均未修复。Apple团队、真机VPN、真实支付仍未验收。Windows回退不声称句柄竞态隔离。

### DIA
已同步PLATFORM_VALIDATION、CHANGELOG、PDEC说明及三端计划的实际状态和Mac风险。

### HLG
按结构化append dry-run/apply追加原始事实链；不将编译/模拟器/隔离交易提升为可用发行。

## 2026-10-07T21:40:51+08:00 · Android正式签名接线通过与Apple用途边界复核

type: development
scope: ["Bettbox", "Android", "iOS", "macOS"]
status: partial
tags: ["three-platform-release", "android-signing", "network-dependency", "apple-networkextension"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 18d45267efe8a9c2338cba0ebac50c9b4f03bad0c6104ac39b40c98c7770b957

### Summary
正式Android身份已创建，正式APK签名接线已应用并独立审阅通过；当前没有实际APK发行交付。Android早期JVM网络门禁已通过，Kotlin资源请求失败于HTTP503；iOS发行用途边界需要重新决策。

### Changed
四文件签名草稿补丁SHA20ed3bf13fe05d918c1f826b7170ffa0ce920291b603aa30dff15d49182bd56a按匹配基线应用。新增platform_extensions.android_release，validator --release校验准确操作；密码仅注入APK进程，正文丢弃，正式单证书锚与最终制品摘要校验。未修改或重建本机签名身份。

### Validation
主控实际57项builder/contract/signing测试通过，日志.test/three-platform-release/android-release-integration-tests.log；独立review无实质P1/P2。统一PDEC与release扩展验证通过，摘要113e680d463a788ff869f5ac64ea3c675f5d02e10fcf337a83b4781b9da93bb5。实际Android网络gate已退出：Gradle缓存/白名单/proxy guard通过，HTTP503来源尚不能区分官方源或任务proxy；来源/锁无漂移、owned Gradle清理verified。

### Next
网络工作包仅两文件补固定代理自产503类别计数并分离有界relay与解析容量，冻结后独立审阅和主控实际网络验证，再正式APK/AVD验收。macOS代理事务方案先只读设计，TUN需受限fd broker。等待用户对iOS专用VPN功能收缩或暂缓发行路线的选择，Android/macOS独立工作继续。

### Risks
未生成/验签/安装正式APK；Apple团队/DeveloperID/真机、真实支付与商户安全注入仍为外部条件。主控核对TN3120官方说明与实际源码：iOS捕获后DIRECT/逐连接proxy出口及any:53存在用途兼容风险，不能依据编译推定可发行；TN3134 direct DeveloperID的PacketTunnel须system extension，不能复制iOS appex。未进行真实资金、系统代理/提权或生产支付操作。

### DIA
已同步SIGNING-POLICY、.pdec/README、PLATFORM_VALIDATION、ARCHITECTURE、CHANGELOG及三端计划。

### HLG
通过HLG append先dry-run再apply记录；索引由工具重建。

## 2026-10-07T21:47:07+08:00 · Android官方依赖容量与签名集成冻结，交付优先Android和macOS

type: development
scope: ["Bettbox"]
status: partial
tags: ["three-platform-release", "android-network", "release-priority"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 7b90a3bada6cd2bbf9f3c0798d7c8aa42d8c89c0a3b35e68d0ad5f2bc8f852f5

### Summary
用户确认先交付Android、macOS，iOS保留开发版并研究发行方案；没有授权收缩为专用VPN。Android网络容量与签名接线冻结，可进入候选提交及实际依赖门禁。

### Changed
任务CONNECT使用32relay+6解析/TCP连接slot、queue12，slot在relay前释放，等待与上游共用绝对阶段deadline；固定代理自产503事件与零值摘要进入history，授权白名单、默认TLS和原始TTL保持。macOS系统代理设计为SCPreferences串行事务与有证据的所有权恢复，设计未实施或执行系统配置。

### Validation
主控实际90项网络、builder、contract和签名测试通过，日志.test/three-platform-release/android-network-signing-integrated-tests.log。独立review冻结两文件无新P1/P2；network SHA d8b76205602d30703e266c763fdba45d2b8784e7590085c900e727fbb8ba8a31，test SHA c336c9a4fd9fd7cc118091a540f82f4551ddb1c46f8884a21644dda703978622。统一PDEC通过，摘要7d194a24bff3a0f20672572b2fd6837ccd338f74d668d48fd8ae9cf2c6d73660；git diff --check通过，任务新增源95文件私钥/长literal-secret模式扫描无命中，不输出值。

### Next
提交推送本任务基础候选，排除.video_agent与忽略的密钥/Vendor/测试产物，再在相同源码冻结下执行一次官方依赖门禁，按固定事件计数定位503，成功后正式APK及AVD。macOS系统代理事务与受限TUN broker仍需实施，真实支付与登录/连接全路径独立验收。

### Risks
90项为mock/本机socket测试，不能代替外网/正式APK/真实VPN。32relay并非永不超载，16MiB仅逻辑转发buffer而非进程RSS。此前HTTP503来源未确认，零诊断计数本身不证明源站健康。正式Apple签名、用户设备和支付商安全配置仍需外部条件。

### DIA
已同步平台验证、签名策略、PDEC说明、三端计划、架构及CHANGELOG的当前范围与验收状态。

### HLG
标准append dry-run后apply记录，索引由工具生成。

## 2026-10-07T22:37:57+08:00 · Android缺陷隔离对照与macOS代理事务核心验收

type: development
scope: ["Bettbox"]
status: partial
tags: ["android-regression", "macos-proxy", "three-platform-release"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 2010eb749693357ebd843161828bab3d964038242107443425e17cd5dd7dae40

### Summary
交付优先Android、macOS，iOS保留开发版研究；执行用户v1.55失败复现与修复后验证要求。正式Android密钥已创建，APK与macOS发行仍未验收。

### Changed
请求头超时仅影响该连接，安全边界拒绝维持全局失败。Gradle清理取内核executable与argc限定argv、核验实际owned home和预检Java摘要，信号前复核身份，主失败与清理失败分开保存。集成Swift系统代理事务核心及23项fake测试，未接入SCPreferences/journal/channel或App。

### Validation
主控实际97项Android网络/构建/契约/签名测试通过，日志.test/three-platform-release/android-regression-integrated-tests.log。scripts/check_android_regressions.py对固定23747c0候选的慢header与带空格Java路径均before=false/after=true，无外网或信号。Swift编译与23项XCTest通过，日志.test/three-platform-release/macos-proxy-core-tests.log。当前PDEC通过，内核argv只读实测未返回环境；Python真实Mach-O与launcher路径不同，不以launcher代替内核身份。

### Next
独立复核清理补丁与公开复现脚本后冻结候选提交推送，在相同来源运行一次正式Android构建。随后安装模拟器验收和完成macOS真实系统配置/连接状态/TUN权限边界。

### Risks
容量调整后的真实Gradle门禁失败，213次上游连接、queue-expired3、header-rejected1；不能归因于官方源或新修复已解决外网。原清理回执失败保持；后续只读检查没有owned JVM不追认原清理成功。签名mock、fake事务测试不证明实际APK/system proxy。Developer ID身份、真机与安全支付配置待外部条件。

### DIA
已同步平台验证、CHANGELOG、架构、macOS实施计划、registry与PDEC说明。

### HLG
通过标准append dry-run后apply追加，派生索引由工具维护。

## 2026-10-07T22:44:53+08:00 · Android清理独立审阅闭合与真实Java身份验证

type: development
scope: ["Bettbox"]
status: partial
tags: ["android-cleanup", "review"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 1cfb8b706d7029257ab569be3ee5f4796ca863b875c0f896239fb11e723216e7

### Summary
独立审阅两项P2已闭合，正式Android实际构建可在冻结候选后执行。

### Changed
同UID/PID候选枚举只在内核入口等于选定JBR时取argv，无FD候选不加入终止授权，初始/最终枚举失败保持cleanup=false。自有Java诊断kill后立即记录信号事实再wait。

### Validation
无FD活worker回归修复前True is not false，修复后通过。100项Android集成测试日志.test/three-platform-release/android-regression-integrated-tests-final.log通过，退出码0。Java无网络公开夹具内核path/argv匹配、环境不返回、自然exit0、signals_sent=false。独立review冻结builder SHA4d069bc007c5e1ce28da457900d78b0600d11fdaf5d7f879df9e609f000847b4无新P1/P2。

### Next
复核当前100项测试退出，候选提交推送后一次正式构建，冻结来源与契约至回执。

### Risks
PID起始时间复核不是内核原子句柄，真实Gradle退出仍需实际证据；macOS公开认证键/Keychain缺项不能证明任意服务无认证，真实适配器范围尚待收敛。

### DIA
同步平台验证、PDEC、CHANGELOG及macOS实施计划。

### HLG
标准dry-run/apply追加，索引由工具更新。

## 2026-10-07T23:24:04+08:00 · 官方Android依赖、Wrapper与ZIP预置候选冻结

type: development
scope: ["Bettbox"]
status: partial
tags: ["android-wrapper", "official-dependencies", "release"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 5f808f406de9ae277394bc36b93b3d342b8d7c03a7b797880c8898cb716f358e

### Summary
Android/macOS优先。真实802d510发行尝试在Gradle help因白名单外目标被拒绝，未生成APK或读签名凭据；未将候选标为发行。新候选补官方仓库、真实Java命名、Wrapper与可验证ZIP预置。

### Changed
QJS仓库只Google/Maven Central，AGP3.5.0/KGP1.3.50不变。未知CONNECT诊断3个固定标签，无hostname/header保留。候选枚举同UID/ucomm java后查kernel；Java身份读取失败保持false，无FD候选不获signal授权。旧Wrapper JAR官方SHA为2.10，从已校验8.14 ZIP中提取官方SHA匹配的8.14 Wrapper，4文件纳入版本控制和PDEC，运行Gradle版本8.14不变。ZIP预置只复用项目内固定大小/官方SHA文件独立副本，无Maven/编译缓存，坏选定源不fallback。

### Validation
主控实际139项工具集成测试通过含33项cache夹具，日志.test/three-platform-release/android-official-cache-integrated-tests-r2.log。静态仓库、受保护非Java和Wrapper真实hash均修复前失败/修复后通过。自有JBR路径/argv/环境隔离/ucomm java/natural exit全部true，signals=false。独立六文件复审及后续cache/接线/Wrapper审阅均无新P1/P2；实际新Wrapper启动及seed尚未执行。

### Next
提交推送冻结候选后运行一次Android debug完整编译，先获得公开编译诊断和AVD安装证据，再正式签名构建。实际Gradle/worker accounting name按允许主类取固定布尔证据；macOS系统代理/backend与TUN边界继续开发。

### Risks
802d510固定事件214上游连接、queue-expired3、target-outside-allowlist1、header-timeout0，确切拒绝主机未知；source/locks true、cleanup false保留。后续只读FD0，候选扫描因2个同UID非Java路径不可读失败；新筛选只读scan count0不追认旧清理成功。PID复核非原子句柄；真实worker命名、退出、APK、VPN/支付、Apple发行身份仍待验收。

### DIA
同步平台验证、CHANGELOG、签名策略、PDEC与registry；公开脱敏失败回执docs/validation/2026-10-07-three-platform/android-802d510.json。

### HLG
标准dry-run/apply追加与工具重建索引。

## 2026-10-07T23:42:27+08:00 · Android实际依赖门禁通过与原生ABI目标修复

type: development
scope: ["Bettbox"]
status: partial
tags: ["android-wrapper", "official-dependencies", "release"]
continuity: resume
continuity-key: three-platform-release
record-fingerprint: 5559e207e68b6aa6bc729ba6599301229ec8564ec7bdd245a10c159c83b8cd01

### Summary
发行优先Android/macOS，iOS保留开发版研究发行。候选1f998ae真实debug构建通过官方ZIP预置、Gradle help/JVM门禁，APK在core CMake配置失败。

### Changed
android/core/build.gradle.kts遵循Flutter公开target-platform映射ABI过滤，未知目标拒绝、未指定保留默认，缺核心检查保持；PDEC输入证据和计划同步。

### Validation
真实CMake stderr明确缺少armeabi-v7a/libclash.so，入口仅生成ARM64。静态回归修复前失败、修复后通过，完整140项工具测试通过；独立审阅无P1/P2。实际Gradle/Kotlin JVM的ucomm、Java入口、任务参数核验，未覆盖worker。真实清理与源码/锁文件不变验证通过，公开回执docs/validation/2026-10-07-three-platform/android-1f998ae.json。Pixel_7启动完成、页大小4096。

### Next
冻结ABI修复候选，完整debug构建验证CMake任务和最终APK，通过后模拟器业务验收与正式签名构建。推进macOS真实系统代理适配、权限代理与状态修复。

### Risks
尚无可交付APK；静态ABI回归不是完整构建证据。模拟器4KB页不能证明16KB设备行为。macOS签名/系统代理/TUN、真实支付和设备VPN仍待验收。

### DIA
已同步PLATFORM_VALIDATION、CHANGELOG、PDEC README/契约及三端计划。

### HLG
使用append dry-run后apply，只追加事实链。
