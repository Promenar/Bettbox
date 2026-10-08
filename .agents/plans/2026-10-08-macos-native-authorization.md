# macOS 系统代理原生授权实施计划

目标是在普通签名宿主中通过系统认证界面取得 SystemConfiguration 事务权限，保留已有 journal/CAS、代次及恢复责任。Android/macOS 为发行验收目标，iOS 为开发研究范围。

## 事实与信任边界

普通进程 SCPreferencesLock 实测 permissionDenied；空独占 journal 恢复已免 SC 锁。当前 64 项 Core、219 项 Flutter、静态分析与完整 unsigned Runner 构建通过。原生引用不进入 Dart、wire、日志、journal 或报告，用户认证信息只进入 OS 界面。采用 Apple scutil 的 AuthorizationCreate(rights:nil, environment:nil, flags:kAuthorizationFlagDefaults) 与 SCPreferencesCreateWithAuthorization(prefsID:nil)；AuthorizationFree使用kAuthorizationFlagDefaults。不调用AuthorizationCopyRights，不额外设置extendRights、preAuthorize或interactionAllowed；不猜测 broad right，不使用 root/setuid、networksetup 或特权 helper。

## 文件所有权与依赖

原生施工独占 SystemConfigurationBackend.swift、Contract.swift、Transaction.swift、Tests/Core/Fakes.swift、TransactionTests.swift 及新增 SystemConfigurationSessionTests.swift；生产新类型保留同文件，避免 Xcode 源文件登记漂移。主控独占 PDEC、公开回执、文档及治理记录。先加入实际可编译注入边界及失败测试，主控集中运行红例后再采用实现；施工冻结后交未参与施工者只读审阅，再集中回归和完整构建。

## 不变量与取消

授权 session lease 内部持有 opaque AuthorizationRef/SCPreferences，失败分支和 close 必须只释放一次；未成功锁定不 Unlock，session 同步/释放在 AuthorizationFree 之前。超时或撤销不释放正在 SDK 调用中的资源。成功、拒绝、撤销及失败均必须先完成SDK返回、同步/解锁及session释放、AuthorizationFree，最后才发出ProxyLifecycle completion；close不得异步尾随。创建明确取消映射 cancelled，明确拒绝或交互不允许映射 permissionDenied；SC AccessError 无法细分原因。commit/apply 未知保持原 journal 恢复责任。

空 journal recover/stop 零授权工厂调用；非空恢复要求真实权限，拒绝保留证据并阻断退出。start 进入授权前和锁返回后检查当前能力，运行双读后、commit 前再次检查；commit 内撤销按实际结果补偿或保留责任，不声称零竞态。

## 验收与回滚

测试显式覆盖已排队start轮到执行前撤销时授权工厂调用次数为零。测试覆盖资源创建失败、锁拒绝/取消、重复关闭、释放顺序、阻塞授权期间撤销、双读期间撤销及非空恢复拒绝。命令为登记的 Swift Core、Host SDK、Flutter、静态分析及完整 Runner 构建。真实 OS 取消/同意、持久/运行双读、恢复、界面启停/退出及上游流量独立验收。引用释放不承诺系统缓存认证一定失效。

有 journal 时先完成实际恢复再回滚；禁止删除证据或恢复旧无授权旁路。夹具不代表系统已弹窗或实际写入成功。

## 集中验证证据

76项基线测试真实出现三条语义失败；生产修复后84项全部通过。首次生产编译暴露C默认flag名称未作为Swift符号导入，依据本机SDK CF_OPTIONS UInt32及Defaults=0三处统一使用AuthorizationFlags(rawValue:0)，不增加权限。宿主SDK编译/夹具与完整unsigned Runner构建通过，源码与锁文件无漂移；未参与施工者独立只读审阅无新增P1/P2。ConfigurationBackend关闭改为throws，清理失败同步升级recoveryRequired并粘性阻断后续空journal洗白。Flutter/Dart代码与已验证219项、静态分析版本相同，无需重复测试。实际系统认证/写入、冷恢复和界面流量仍待验证。
