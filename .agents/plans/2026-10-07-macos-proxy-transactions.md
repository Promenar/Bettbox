# macOS 系统代理事务实施计划

## 目标与边界

系统 HTTP、HTTPS、SOCKS 与 bypass/PAC 状态由串行原生事务管理。只有实际应用、持久所有权记录和当前设置匹配时恢复原值，保留外部修改。Linux、Windows、TUN 与 Network Extension 不属于该工作包。

## 核心与施工所有权

- `plugins/proxy/macos/Classes/Core/`：类型化字段组、事务状态机及生命周期代次。主控集成已独立审阅的核心；所有服务认证未知或已配置认证时，必须在写入前拒绝。
- `plugins/proxy/macos/Tests/Core/` 与 `Package.swift`：实际事务逻辑使用 fake 配置与 journal 验收，测试不访问系统代理或真实用户配置。
- 实际 SCPreferences、受保护 journal 和 Flutter channel 由后续独立工作包实现；实施前确认接口、原生插件注册、权限以及运行状态核验方式。当前核心未接入 App，不代表现有 networksetup 路径已修复。
- Dart 协调器、错误国际化、系统代理实际状态和托盘刷新在原生契约稳定后接入；不得把用户偏好或内核运行等同系统代理已生效。

## 不变量与故障处理

生命周期代次分配与入队在同一锁内，回调在锁外。未提交启动可取消；提交期间取消必须完成核验及必要补偿，不能放弃事务。

只有 verifiedApplied 记录及持久/运行双读匹配组允许自动恢复。prepared、committed、uncertain 不自动认领 localhost 设置；无法证明实际应用时保留 recoveryRequired。原始 before/written 证据保持不可变，已恢复组与剩余冲突组受集合约束并持久记录。最终 journal 保存失败不得报告持久恢复完成。

真实适配器必须使用 SCPreferences 配置锁，区分 Commit 与 Apply，保留未知字段与键缺失语义。不得读取密码、猜测私有认证字段、输出 PAC URL 或系统配置；无法证明无认证时拒绝接管。安全 journal 使用用户保护目录、文件锁、拒绝链接、原子写入及 fsync，实际实现需独立审阅。

## 验收与发布条件

纯核心入口：`swift test --package-path plugins/proxy/macos --scratch-path .test/three-platform-release/macos-proxy-core-build`。入口已登记 PDEC，当前来源校验通过；真实编译及23项隔离 fixture 通过。结果不包含系统代理或 App 接线。

核心验收后完成真实 SDK 编译、Dart 协调器与错误状态测试，再在明确受控的测试服务验证权限拒绝、写入/恢复、外部修改、网络切换与进程退出。不能自动对日常网络服务做破坏性试验。

已有 macOS 应用尚未包含事务核心，为 ad hoc 候选，嵌套签名检查失败。本机仅确认 Apple Development 身份，Developer ID 发行证书缺失；本地开发签名、Keychain、正式签名/公证和业务连接必须分别验收。

公开SDK认证能力已只读核验：macOS15+公开HTTPUser/HTTPSUser/SOCKSUser键仅能保守识别认证线索，缺失不能证明无认证；Keychain精确搜索无结果也不能证明服务所有认证存储为空。适配器须先收敛可证明的服务接管范围，不能把fake.absent直接用于任意真实服务。

## 专用入口与控制信任候选

现有事务的absent门禁保持，真实适配实施前先验证独立专用入口的凭据隔离与可信控制能力，再裁定unknown服务接管契约；不伪造absence。当前HTTP即便无认证器仍解析代理认证并生成用户名日志/metadata，SOCKS5密码方法可进入AlwaysValid。专用HTTP/CONNECT入口须绑定127.0.0.1:0、隔离订阅配置，认证解析前删除代理认证字段且不生成inUser。普通HTTP/Upgrade输出请求与输入Trailer必须分离，丢弃输出Trailer，拒绝声明的代理认证Trailer；CONNECT拒绝正文/Trailer。目标站Authorization保留。首包只拥有HTTP/HTTPS，SOCKS须持久/运行未启用，PAC/WPAD只拥有启用位并保全未知URL。

原生UDS处理frame前核验双方UID、peer audit token/PID和预期代码身份，并绑定应用本次实际启动的core；使用私有0700目录、0600socket、拒绝链接和TCP降级。能力绑定可信连接、代次及真实监听，断线退出即失效。当前Dart首连接不具备此证明，单一能力字段不能替代身份核验。真实SDK、签名及进程生命周期策略须在实施前定约并独立审阅。所有权按入口、生命周期、原生传输、SC后端、Dart接线串行交接。验收使用虚构认证标记覆盖普通/CONNECT/Upgrade、Trailer EOF、原认证不变、伪造首连接/错误PID/旧代次/断线及未知配置键保全；不读取真实凭据。专用入口与传输尚未实现，TUN独立推进。

## 专用 HTTP 入口实施与验收（2026-10-08）

目标是在 Mihomo fork 增加固定 127.0.0.1 临时端口、无凭据解析的 HTTP/CONNECT 构造器。该入口保持目标 Authorization，移除代理认证 Header/Trailer，不提供 SOCKS；现有默认入口与认证行为保持兼容。容量为 32 个连接、64 个内部路由，头预算 32KiB/15秒；正文与持续连接不设置总量或绝对寿命限制。停止以 handler、pipe、route 与 watcher 实际退出为依据，等待超过一秒返回未完成。

文件所有权：主控串行集成 core/Clash.Meta/listener/http/credential_blind*.go、client.go、upgrade.go；不接线系统代理、不修改用户网络设置。独立静态审阅无阻断项，实际测试结果单独记录。匿名管道与 Android 启动状态另属独立工作包，不在本入口中放宽信任门禁。

验收：Go 本机执行只读依赖锁、禁用依赖网络的 -race -count=1 HTTP 包测试，覆盖流式大上传/下载、CONNECT、Upgrade、pipeline、EOF、关闭未完成和认证隔离。失败先定位 fixture 或生产实现原因；实际可用与系统代理恢复仍须后续原生集成。回滚仅删除新增入口并还原两个现有文件的本任务补丁。
