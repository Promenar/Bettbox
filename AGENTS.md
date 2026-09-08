# Bettbox 项目开发规范

> **Version**: v2.0 (2026-09-09)
> **Scope**: Bettbox 跨平台代理客户端项目
> **遵循标准**: [AGENTS.md 开放标准](https://agents.md/)，继承全局开发规范
> **治理变更**: v2.0 按 HLG 重建治理体系，治理根由 `.agent/`（其它客户端遗留，已作废）迁移至 `.agents/`

---

## 1. 全局规则继承与工程协议

本项目严格继承全局开发规则：
- **语言规范**：所有解释、规划、文档、注释必须使用**简体中文**。
- **闭环工作流**：`Plan → Implement → Audit → DIA → Commit`，任务完成前必须执行 DIA 检查。
- **文档治理（HLG）**：遵循 `handover-lifecycle-governance` Skill，治理根为 `.agents/`：
  - `.agents/registry.md` — 文档注册表与治理根声明
  - `.agents/handover.md` — 跨会话交接事实链（append-only，禁止直接编辑）
  - `.agents/handover-index.md` — 可重建导航索引（禁止手工维护）
  - `.agents/plans/` — 架构设计与实施计划存档
- **非微小变更**：架构设计与实施计划存档于 `.agents/plans/` 目录。

---

## 2. 技术栈与架构基准

- **框架与语言**：Flutter (Dart `>=3.9.0 <4.0.0`)
- **核心内核**：Mihomo (Clash Meta) 内核
- **状态管理**：Riverpod (`flutter_riverpod`, `riverpod_annotation`, `riverpod_generator`)
- **网络与序列化**：Dio, `json_serializable`, `freezed`
- **目标平台**：
  - Android (8.0+)
  - 桌面端：macOS (Apple Silicon / Intel), Windows (x64 / arm64), Linux (x64 / arm64)
  - iOS (立项阶段)
- **商业化专版扩展**：`lib/xboard/` 体系（Xboard 面板 API 对接、多域名调度/故障转移、节点商业包装/脱敏、安全存储）

---

## 3. Flutter / Dart 编码红线

1. **Riverpod 状态提升与响应式**：
   - 优先使用基于注解的 code-gen 模式生成 Provider。
   - 避免无控制的 `ref.watch` 引起整树高频重绘，粒度控制到需要渲染的最小 Widget。
2. **异步与线程安全**：
   - 复杂的配置转换与解析（如节点打包 `NodePackager`、大量规则清洗）需注意计算开销，避免阻塞 UI 线程。
   - 敏感凭证（如 Xboard Auth Token、密码）必须走 `lib/xboard/secure_store.dart`（基于 `flutter_secure_storage`），严禁明文持久化在普通 SharedPreferences。
3. **国际化与多语言**：
   - 新增 UI 文案必须同步更新 `arb/intl_*.arb`，并使用 `intl_utils` 生成代码，严禁在页面中硬编码中英文字符串。
4. **单元测试与回归**：
   - 业务逻辑与核心转换（如 `test/xboard/`）必须配套单元测试，修改相关模块必须保证 `flutter test` 全部绿灯。