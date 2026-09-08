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
