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
