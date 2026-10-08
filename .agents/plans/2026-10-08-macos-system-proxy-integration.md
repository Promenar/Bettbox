# macOS 系统代理接线计划

目标是让正常应用使用受可信原生会话约束的专用 HTTP/CONNECT 入口，并在关闭、重启及异常退出时保留代理恢复责任。Android、macOS 优先交付，iOS 保留开发版及发行研究。

## 已核对的源码事实

- Go owned session 提供 ownedHttpStart/Get/Stop；endpoint 固定 loopback、临时端口及单调 listenerEpoch。native Ticket 持有 Core proof 与 opaque handle，Dart Application 不拥有这些授权对象。
- SC 事务、白名单字典合并、schema3 journal 和串行生命周期已存在，尚未接入 Runner 正常应用路径。Transaction 的启动、恢复及匹配检查要求 authentication=absent，真实 SystemConfigurationBackend 恒报告 unknown；不能伪造 absent。
- 当前 macOS Proxy 仍使用 networksetup，且正常 Application 的停止顺序先关闭 RPC；系统代理恢复必须排在专用 endpoint/Core 释放前。

## 接线边界

主控串行负责 HostSystemProxyCoordinator、HostSupervisorAuthority/FlutterBridge、Runner 工程及 Dart Session/Application/ClashService/ProxyManager/退出流程。SC 核心复用同一源码，不复制第二份实现或创建可绕过 native Ticket 的通道。Dart Session 私下附加 handle；native 验证 Ticket/Core proof、generation、loopback、port、state、listenerEpoch。endpoint 参数本身不是授权。

冷启动先恢复 journal；仅 idle/restored 可进入新代。开启顺序为握手与配置完成→ownedHttpStart→native SC apply→实际生效状态。正常关闭为 native restore→ownedHttpStop→RPC close→session revoke→helper/Core exit及EOF确认。恢复冲突、未知或失败时保留 endpoint/Core/journal，并阻断重启与强制退出。Core 意外死亡后恢复仍不依赖存活 proof；不能承诺掉电或SIGKILL零断网窗口。

## 关键未知与必要裁定

专用入口凭据隔离不等于能证明系统认证 absent。需要独立 native-only 安全能力契约与失败测试，确认只拥有 HTTP/HTTPS/bypass/PAC启用位、保全未知认证配置，真实服务仍报告 unknown。不得允许 Dart 传任意放宽标志。SCPreferences 写入权限及 Authorization Services 系统交互需按实际证据确定，不能引入 root/setuid 或 networksetup 回退。prepared/committed/uncertain journal 不能直接清除或凭时间自动接管；可确定恢复分支需单独设计和审阅。

## 验收与回滚

Swift 覆盖旧 handle、错代、epoch回退、proof失败、提交中撤销及恢复冲突。Dart 覆盖快速开关、重启/apply交错、SC失败后入口收尾、恢复失败取消退出及RPC fatal恢复。运行现有 Swift/Host/Flutter 全量检查与 Runner 实际构建；真实受控服务验证权限、持久/运行双读、恢复、外部修改、网络切换和退出，最后验证有效账户HTTP/HTTPS流量。未经真实行为验证不得称可用发行。

回滚只撤除未采用接线；有未确认 journal 时不得退回共享listener、旧networksetup路径或删除恢复证据。

## 接线信任模型与产品范围

正常发行包中的已验证宿主、签名Dart业务代码与固定Core共同属于可信应用基；不宣称native能仅凭Dart中转端口独立证明credential-blind构造器。Session私有handle与固定ownedHttpStart RPC回包的推导路径纳入审阅，native继续核验Ticket/Core、精确endpoint字段及单调epoch。未知认证状态如实保留，授权由不可序列化的内部安全能力提供，不开放任意allowUnknown布尔开关。用户已有bypass偏好应保留，native进行类型、数量及语法校验；不能以未授权的固定清单收缩正常产品功能。

允许unknown之前必须把未拥有字段摘要作为服务级持久/运行双读守卫：任何认证或未知字段外部改变均禁止恢复拥有字段。已识别present保持拒绝。credential-blind保证凭据不进入认证器、metadata、转发或已检查日志；不声称解析过程从未在内存物化原始header。非verified journal先仅考虑全owned字段已双读before时零配置写入清理；其他自动补偿须形成独立计划及回归，不能凭phase或时间清洗。

## 事务核心实施包

施工范围独占 `plugins/proxy/macos/Classes/Core/` 和 `plugins/proxy/macos/Tests/Core/`；宿主、Dart、工程、PDEC、registry与交接记录由主控串行集成。核心施工不访问真实配置、Keychain或外网。先建立当前实现能编译运行的失败回归，再扩展 schema4 合同；主控同步输入摘要并验证 PDEC 后运行登记的 Swift 测试。实现由未参与施工的审阅者复核，再接入宿主。

schema4 保存 credentialBlindHTTPv1 endpoint 来源证据（supervisorGeneration、listenerEpoch、127.0.0.1、与 intent 一致的有效端口）、独立 transactionGeneration、服务级 persistentUnownedDigest 与 activeUnownedDigest。来源证据只供恢复审计，不能反序列化为启动能力。启动能力为不可序列化的内部对象，使用原生可信会话校验与当前性检查；认证 unknown 如实保留，只有有效能力允许该专用入口，present 必须拒绝。

摘要仅排除实际拥有的 HTTP/HTTPS 三字段、bypass、PAC/WPAD 启用位；SOCKS 全字段、PAC URL、认证及未知字段必须纳入。持久和运行摘要分别保存各自基线，不要求跨来源摘要相等。stage 从新鲜原字典白名单合并并核对摘要；提交、验证、重复启动及恢复均检查当前性和双读守卫。能力撤销或代次取消发生在提交后时进入补偿流程，不能宣称未写入。

schema3 使用独立历史类型及严格 canonical 解码，不默认补入新字段、升级、删除或赋予新能力；存在旧 journal 阻断新启动。旧 verified 恢复只遵守历史 absent 合同，真实 unknown 保留 recoveryRequired；旧非 verified 不自动清理。未知 schema、损坏或非 canonical 数据保留原证据并拒绝。

schema4 非 verified journal 只允许所有 owned 组持久和运行均等于 before、服务稳定且启用、双摘要等于基线时零配置写入清理；written、混合、外部改变、缺失或 present 均返回 recoveryRequired 并保留 journal。verified 恢复仅对仍等于 written 且守卫未变的 owned 组执行 CAS，最后双读 before 和摘要通过才清除 journal。恢复不要求活着的启动能力。

测试至少覆盖 SOCKS/认证/未知字段改动摘要、持久与运行基线独立、unknown 专用能力及 present 拒绝、能力失效和提交撤销、v3 canonical 兼容、v4 零写清理与保守拒绝、恢复 CAS 冲突和 clear 失败。实际权限、宿主授权路径、端到端流量和发布签名独立验收，不以核心夹具替代。

## 宿主与正常应用实施合同

HostSystemProxyCoordinator唯一持有ProxyLifecycle；生产工厂只组装，不在主线程做SC或journal IO。同份Core直接编入Runner/Host测试模块，不复制或扩大public。Host state只异步投递SDK/SC工作，能力current仅读NSLock lease；SC worker不sync回state。冷recover仅idle/restored且零unresolved允许reserve，最多挂起首个请求；其他请求固定拒绝。恢复参数不依赖活proof，不接受路径或任意配置。

固定方法为activateOwnedSystemProxy（精确handle、generation、listenerEpoch、host、port、state、bypass）、restoreSystemProxy（generation、listenerEpoch）、recoverSystemProxy（空map）。SC结果精确status、transactionGeneration、changedGroups、unresolvedGroups，固定枚举及有界整数；Core代次与事务代次独立。原生在同一Ticket/私有coreHandle/proof/内核链两次核对之间执行SDK recheck后才mint能力。recover必须失效等待SDK的旧activate；迟到结果不能重新mint或发布active。同epoch只允许相同已活动endpoint幂等，更大epoch必须先恢复。未知/pending保留责任并阻断confirmStopped、新reserve和退出。

SupervisorApplication统一串行运行、代理偏好、配置、restart/shutdown；业务准入有界。正常收尾先原生restore，再通过未关闭的私有RPC发ownedHttpStop并核对同代/同epoch/stopped，然后RPC close、Session revoke、stdin close与既有EOF/出生消失确认。内部RPC不走自身preload/生命周期队列，避免自锁。Session全部故障、启动失败、迟到spawn也必须独立经过无proof恢复门禁；非idle/restored保留Core/stdin。

Go专用owner会在initClash/setupConfig/updateConfig/shutdown前关闭endpoint，故这四类RPC都必须先恢复SC和关闭入口，配置成功再按最新运行/代理偏好重建入口；旧startListener/stopListener明确被拒绝，Mac Service必须覆盖。state仅实际成功后提交运行时间与prefs，ProxyManager转交偏好且不调用networksetup。macOS退出失败保留窗口/tray、恢复责任并允许重试，不能finally无条件exit或先清停止标记。

冷空journal当前仍先configuration.lock；permissionDenied/busy可能阻断未接管的应用，这是源码确定的顺序及未验证运行风险。判空免SC锁如需采用须独立Core失败回归和审阅，Host包不能隐式改语义。SC写入权限、Authorization Services与真实生效独立验证，不采用root/setuid回退。

## 冷启动权限实测与空记录恢复

普通宿主非阻塞SCPreferencesLock真实返回permissionDenied，signature未变。recover/stop必须先在串行锁及已取得journal独占权下严格加载；仅可信nil允许返回idle且不获取SC锁。有记录、读取失败、损坏或所有权未知不得据此跳过恢复；非空记录仍保留原双读/CAS及权限门禁。start必须获取SC锁。三项针对性回归先真实失败再实施，保持同份Runner核心。探测脚本仅锁/释放/签名比较，不stage/commit/apply或提升权限。

旧macOS authorizeCore源码仍有chown/chmod setuid路径，必须在任何完整Runner交互前移除；固定入口先拒绝，不初始化路径插件或权限进程。基线危险权限调用不执行，替代证据为已读取的旧源码、移除diff、实际macOS公开入口拒绝测试及静态分析。TUN保留未实现边界，界面以国际化提示拒绝，不借此把系统代理升级为完整VPN验收。

## 正常应用集中验证

配置就绪以初始化和有效配置两项代次事实确认，冷启动update不能创建配置事实；偏好只在最新意图实际成功后确认，失败同值必须重试。当前219项Flutter测试全部通过、静态分析无问题，完整unsigned Release构建成功且源码和锁文件保持一致。SDK警告不作为行为验收。系统代理Authorization Services须独立计划、夹具验证、审阅与签名Runner交互；实际SC写入、恢复、普通界面流量和退出未验证。macOS TUN为明确不可用边界。
