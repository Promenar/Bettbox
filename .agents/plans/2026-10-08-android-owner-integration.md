# Android 配置与生命周期联合接线

目标是由一个原生 owner 统一前台、后台、快捷磁贴、智能切换、配置提交和资源收尾，并向客户端报告真实完成事实。正式编译、模拟器启动、夹具验证和真实 VPN 流量分别验收。

## 已核对事实与边界

`ServicePlugin` 的启停方法立即返回 true；Dart 的 state、smart manager 和后台 main 存在提前提交运行状态的路径。原生 STOP 事件缺少请求关联，Dart 的早期清状态还会使 controller 的 STOP 分支失效。权限回调只有成功分支，缺少拒绝、无 Activity 和旧结果归属处理。

配置候选 `AndroidNativeOperations` 与 `NativePreparedConfig` 已有进程唯一实例、operation Mutex、配置 journal、ENTERED/Applied 归属和30项夹具；尚未接入实际 App。其 borrowedFd/closeOriginalFd 不能直接覆盖实际 detachFd→TunFDLease→JNI领取→Go采纳合同。现有 VpnWorkGate/VpnLifecycle 的平台失效票据可保留，但不能与唯一 owner 竞争发行权威代次。

前台 setup/update/setState、后台 quickStart、IPC reconnect、listener/shutdown及 HTTP patch/update均须纳入同一 owner。Go runLock 只防局部数据竞争；options与TUN快照尚无共同配置版本。上述为源码未封闭边界，尚无设备竞态复现。

## 实施与所有权

先采用并扩展既有 owner，增加不可变 typed completion；在 owner 内分类、提交、捕获 snapshot 后才释放执行锁。Boolean 兼容接口从同一次 completion 派生，不能 await bool 后重读后来状态。权限、绑定及建立等待可撤销；已进入同步提交或 JNI 的工作不能因调用者取消丢失归属。输入 FD 仅由当前领取合同关闭一次。

Go 提交器分配配置 revision；同步 JNI backend 在首个副作用前登记 ENTERED，并在实际完成后从同次提交派生复制 options。TUN 启动核验该版本对应快照。增加 setState 的类型化 mutation，关闭直接配置写旁路，保留实际热更新与 HTTP 功能。尚未 ENTERED、仍为当前意图的排队配置遇到版本推进时，只能由同 owner 重新准备；不修改旧 payload 的 baseRevision 冒充新准备，不让后台再次 beginStart 覆盖用户 STOP。

receipt ledger 不执行 JNI、不接纳生命周期意图、不分配 generation。它仅关联 requestId 与 owner handle，保存不可变结果并在主线程 exactly once 投递。wire 字段为 requestId、generation、revision（owner stateRevision）、configRevision、ownedGeneration、outcome、phase、smartStopped、startedAtMs；配置版本与生命周期发布版本职责独立。

completed 只表示目标真实完成；拒绝为 rejected，撤销为 cancelled，建立失败且收尾已确认可为 failed，原生停止/FD关闭/配置归属不确定为 unknown+blocked。超时不清 owner 或自动解除恢复锁。旧请求回执不得拼入后来请求的 snapshot。startedAtMs 只在真实 running 提交产生，确认 stopped 后清空。

service/vpn 两通道共用 typed dispatcher。前台 state/controller/manager 与后台 main/tile 仅在确认后更新运行时间、持久标记及流量。普通全停先确认 TUN，再 checked listener 收尾，再服务/绑定清理；智能暂停保留恢复所需资源。后台 engine 收到回执并确认 ack 后，重新核对 owner 已停止且无新操作，才允许自动销毁。

主控负责 Go/JNI 合同、Dart接线、PDEC、聚合文档及交接；原生 owner/adapter 与跨层审阅按稳定接口分包。共享聚合文件串行；实际施工前明确精确文件所有权。macOS SC核心包与 Android 不共用源码，可独立施工。

## 验收与回滚

红回归直接使用生产 owner/backend/ledger：旧配置提交被 STOP 替代、取消后真实 Applied 保留、A options不能配B快照、排队版本推进的同意图重准备、无 Activity/权限拒绝/旧结果、旧回执晚投递、重复 stop、未知停止不清状态、不销毁 engine、listener close未知及直接旁路拒绝。Dart测试必须覆盖真实 state/manager/main入口，不能用镜像控制器替代。

主控更新 PDEC 输入摘要并确认 execution_ready 后执行登记的 JVM/Go/Flutter检查、正式 Android 编译、独立串行审阅与模拟器验收。设备同时核对请求、权威状态、真实TUN、listener、通知和界面；有效上游节点协议流量另验。出现未知 owner/journal 时保留恢复责任，不通过卸载、清数据或旧旁路清洗。回滚仅撤除未采用代码；已采用资源按确认收尾合同恢复。

## Go/JNI与平台adapter定稿要求

配置准备对象只带baseRevision和载荷，不由调用方指定实际revision。Go同步提交在同一配置锁校验expectedConfigRevision、登记ENTERED、分配revision、完成提交并复制同次Android options；返回Applied(configRevision, options)，不能事后getOptions拼接。TUN启动增加expectedConfigRevision，在同一锁核对相应快照并采纳输入。suspend、TUN stop、listener stop和shutdown需要真实checked结果；void不得制造完成证据。具体同步入口及callback载体由主控结合现有Go/JNI定稿。

owner执行锁内分类和捕获immutable NativeCompletion(generation, operation, outcome, snapshot)，之后完成Deferred。候选borrowedFd模型不采用：adapter在入Core前取消时关闭自身正数输入；入Core前标已交接，现有TunFDLease peek/claim/finally及Go采纳合同负责关闭一次。关闭失败永久blocked不得由后续true清洗。VpnLifecycle不发行第二套权威generation，WorkGate仅作为唯一owner下的adapter单元，protect和断连带本lease身份。

权限等待区分Granted/Denied/NoActivity/Cancelled/LaunchFailed，旧结果不能复用为新请求；配置detach保留等待、永久detach完成并清引用。receipt ledger仅关联owner handle并主线程once投递，不能分配generation/revision。engine ack须requestId、revision、engine身份都匹配，owner仍同一stopped状态且无lease/新工作/unknown才可锁内摘取并主线程锁外destroy；缺ack保留engine。

## 初始状态、HTTP兼容与跨层提交合同

普通冷启动（lib/controller.dart 的 _initCore）在 init 后先 setState，随后 _setupCoreConfig 才提交配置；Android quickStart 同样按 init、state、setup执行。未配置时 getAndroidVpnOptions 没有合法快照。owner必须区分UNCONFIGURED、CONFIGURED和BLOCKED：UNCONFIGURED的setState在operationMutex内按现有部分合并语义校验、深拷贝并保存desiredState，返回STAGED/stateGeneration；旧bool兼容映射true，但不分配configRevision或伪造Applied/options。

首次setup在同一锁内准备不可变initial composite，绑定Core lifecycle epoch、setup载荷及最新desiredState。Go端完整校验两者，校验阶段不得更改DefaultTestURL、currentConfig或任何共享状态；首个可见副作用前记录ENTERED并分配真实revision。成功从同次提交生成options并标记消费stateGeneration。校验失败保留staged状态允许显式重试；ENTERED后的未知错误保留责任并BLOCKED，不冒充UNCONFIGURED。现有shutdown不清state，缺desiredState的合法低层调用需显式取得并固定原state snapshot，不能假设默认值。quickStart是单次owner操作，不保留旧FFI旁路。

同步commitNativeConfig/commitAndroidConfig携带epoch、expectedRevision、固定mutation kind和canonical载荷；结果包含outcome、phase、epoch、configRevision、options、固定errorCode。prepared载荷不能原地重写base。Go runLock覆盖revision核验、提交和options快照；startNativeTun/startTUNChecked在同一runLock核验epoch/revision并实际采纳FD，防止A options配B配置。保持现有peek、global ref、claim和Go FD lease采纳合同，不能换成borrowedFd。任何领取后拒绝仅在FD/ref检查式清理确认后返回rejected，否则unknown。

HTTP PATCH/PUT保留无新headers客户端兼容。route只规范化CanonicalHttpMutation，不直接写setter或ApplyConfig；在不持有Go/listener锁时提交唯一Native owner。缺requestId由owner发行，提供则严格UUID；缺base只在owner首次prepare时读取最后真实Applied revision，提供base严格CAS。活跃VPN变更先撤销旧lease准入并确认旧TUN/监听关闭，再提交、按同次options重建并发布新代；不允许旧lease使用新config。锁序固定为HTTP无锁、Native operationMutex、Go runLock、内部锁。

Go→JNI→Kotlin→JNI→Go回入需真实Android线程附着、CheckJNI及异常清理验证；不能以静态编译代替。ENTERED后客户端断连不取消实际提交。receipt仅保存在同Core lifecycle epoch的有界内存，带容量和TTL，不落盘、不保存config/body；进行中不驱逐，容量耗尽在受理前拒绝。保留期同requestId同digest合并/重放，异digest冲突；epoch换代或过期查询明确miss，不能解释为从未执行。generation、epoch与revision必须独立绑定，不能在新epoch重复revision而省略epoch。

## 检查式监听关闭接线

现有listener.StopListenerChecked已持真实槽位锁、尝试所有登记资源、保留失败对象供显式重试。handleStopListener当前void StopListener后始终true，需接入既有检查式入口；isRunning=false仅阻止新监听更新，不证明已关闭。生产handler与action回归使用公开InboundListener，通过正式PatchInboundListeners注册，不创建系统TUN或公网连接；覆盖失败、panic、其他对象继续关闭及重试。此修复不等于整个Go runtime/provider/controller退出，shutdown/suspend的更强合同独立实施。
