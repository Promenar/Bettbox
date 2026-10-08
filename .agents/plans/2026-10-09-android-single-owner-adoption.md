# Android 唯一原生所有者联合采用

## 目标

Android 前台、后台、快捷磁贴、更新恢复和智能启停共用唯一配置与生命周期所有者，报告真实资源完成状态。直接运行的正式候选必须采用这条全路径；不把独立 helper、未启用分支或解析器测试当作采用完成。Android/macOS 可用发行、服务端账户/订阅/邀请/支付、iOS 开发版及发行研究的总体目标保持完整。

## 当前事实

源码 a35d73f 已具备 owned 配置/TUN JNI、严格协议解析器和 FD 领取合同，但 VpnPlugin 使用 Boolean 启停。ServicePlugin.startVpn 丢弃受理 false，Dart 主后台存在提前提交运行态和独立读取 options。Android 没有排队前用户停止 epoch，后台 quickStart 跨多个 await 未核验原意图。

Go 配置 epoch 当前为常量1；lastApplied 是成功提交的 attempt，stateGeneration 独立。TUN 停止必须使用启动资源的 epoch/configRevision/generation，不能传本地新 stopGeneration。公共 hub init/state/setup/update 与监听启停/shutdown 已有同锁旧入口门禁，覆盖 STAGED、提交责任、configured、blocked 和 TUN reservation；畸形 setup 在解析前拒绝。未采用路径保持工作，内部 owned driver 不经过公共门禁。实际失败复现、主包回归及配置32轮并发race证据见 android-legacy-admission-validation.json。quickStart 在采用后会被 init/state/setup 拒绝，须同批接入 owner，不能依赖拒绝门禁继续启动。ownedListenerMode 启用点属于 darwin；legacy TUN 与带身份 listener/shutdown 仍待联合接线。

实际 a21276f APK 只有一份 ARM64 libclash.so，JNI ELF 动态依赖按 basename 指向它；这证明打包与链接事实，不证明设备上的 Dart/JNI 同一 coordinator 实例。a35d73f 正式签名 APK 的更新资格基础设备证据独立归档，不能关闭联合采用或有效节点流量门禁。

## 原子范围与所有权

主控串行持有核心契约、共享聚合文件与集成：core/android_config.go、android_tun_owned.go、android_tun_reservation.go、lib_android.go、hub.go、action.go及必要的 checked listener/shutdown 入口；Android Core、严格解析器、GlobalState、VpnPlugin、ServicePlugin、TilePlugin、平台服务和统一 owner/ledger；Dart controller/state/main、service/vpn/tile、clash 的实际配置/FFI/IPC adapter；对应测试、PDEC 和文档。实际施工须先确认准确文件与调用图，不扩大到节点凭据、系统 DNS、root 权限或用户 .video_agent。

所有施工文件由一个主控串行集成；稳定且不重叠的工作包才委派。高风险采用后由未施工者独立复审，源码检查、编译、设备行为和有效上游流量分别验收。

## 强制合同

- 所有入口受理请求身份和原用户意图 epoch。用户停止在等执行队列前登记；配置、权限、绑定、JNI、前台发布、Dart 消费阶段核验原意图，后台重试不得创建新授权覆盖停止。
- 原生状态读取提供配置身份；首次 composite 的 kind4 同次提交 setup/state。STAGED 不代表可运行；APPLIED 回执携带不可变 options，禁止提交完成后另取后来快照。排队版本推进由同 owner 重新准备，不篡改旧 baseRevision。
- 运行时 epoch 来源及重初始化撤销须关闭 ABA；设备须证明 FFI/JNI 共用同一 runtime/coordinator。不得把固定1或 Flutter 代次当作该证明。
- 配置修改前按旧资源身份确认释放 TUN reservation。启动联合核验实际 Go 回执、最终 FD lease、平台服务和当前请求；实际前台完成才提交 START，并授予更新恢复资格。
- 普通停止撤销资格并捕获旧资源身份；智能暂停保留既有资格。IDLE 停止由 owner 证明资源为空，不伪造正数身份。未知资源/FD/配置状态保持 blocked，不允许 bool 清洗。
- 公共旧写入口的拒绝判断与实际写入在同一 runLock 下；首次 STAGED、owned ENTERED/采用或 BLOCKED 后均阻断。quickStart 在 init 副作用前拒绝。内部 prepare/commit/updateConfigLocked/state.Replace 为真实 owned driver 服务，不得误拒或重复加锁。
- legacy TUN、listener 和 shutdown 收敛到同一 owner；拒绝启动仍须收尾输入 FD 和回调，不能泄漏。无权限/撤销/旧回调/无 Activity 都必须完成原请求。
- 两 channel 返回同一 immutable completion，Boolean 兼容只由它派生。requestId、generation、stateRevision、configRevision、ownedGeneration、phase/outcome、smartStopped、startedAtMs 和消费者 engine 身份职责明确；不能 await bool 后拼后来状态。
- Dart 仅消费自身请求的完成事实，再提交运行时间和偏好；旧事件不得清新会话。消费 ACK 同时匹配请求、完成 revision 和 engine。destroy/handleTryDestroy 共用退出准入，无新工作、无资源责任、无必要未消费回执、无 unknown 才进入 EXITING；销毁在主线程锁外，退出期间新启动排队。

## 实施与验收顺序

1. 固定唯一 owner、意图、配置与资源身份、completion/ACK 数据合同；精准封闭实际 FFI/IPC/action/HTTP 写入和生命周期旁路，保持内部 driver 的真实工作路径。
2. 同批采用两个 channel、平台启动/关闭、Dart 主后台配置和状态消费及 engine 退出；不能把启停 Boolean 替换当作这一批完成。
3. 生产路径回归先复现旧写污染、停止排队先于迟到启动、旧完成清新会话及 ACK 退出缺口，再验证实际 owner/backend/ledger。未知关闭和缺 ACK 不销毁、不发布 stopped。配置 A 的 options 不得与 B 的快照配对。
4. PDEC validate 后运行相应 Go race、生产 JVM、Flutter 全回归/静态检查、实际 release Kotlin 和正式 APK 构建；独立复审后在固定同源设备验收。
5. 设备覆盖主后台首次启动、普通/智能停止恢复、权限撤销、配置重启、两个 channel 并发、Binder/前台异常、迟到回执、ACK 丢失/重复、engine detach/退出及 SDK36 更新；同时核对 UI、通知、JNI/FD责任和活动组合 VPN transport。有效节点 HTTPS 流量必须另外证明。

出现旧写仍可进入、来源 runtime 不同、无原意图请求、未知 FD/资源、未消费回执被销毁或未确认完成发布时停止发行验收。回滚只撤除未采用的源码；已采用资源须按确认收尾合同恢复，不通过卸载、清数据、legacy stop 或扩大权限清洗。
