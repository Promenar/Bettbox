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

配置准备对象只带baseRevision和载荷，不由调用方指定实际revision。Go同步提交在同一配置锁校验expectedConfigRevision、登记ENTERED、分配revision、完成提交并复制同次Android options；返回Applied(configRevision, options)，不能事后getOptions拼接。TUN启动增加expectedConfigRevision，在配置锁内核对并发行reservation/值快照，锁外构造和采纳输入，完成后核对reservation。suspend、TUN stop、listener stop和shutdown需要真实checked结果；void不得制造完成证据。具体同步入口及callback载体由主控结合现有Go/JNI定稿。

owner执行锁内分类和捕获immutable NativeCompletion(generation, operation, outcome, snapshot)，之后完成Deferred。候选borrowedFd模型不采用：adapter在入Core前取消时关闭自身正数输入；入Core前标已交接，现有TunFDLease peek/claim/finally及Go采纳合同负责关闭一次。关闭失败永久blocked不得由后续true清洗。VpnLifecycle不发行第二套权威generation，WorkGate仅作为唯一owner下的adapter单元，protect和断连带本lease身份。

权限等待区分Granted/Denied/NoActivity/Cancelled/LaunchFailed，旧结果不能复用为新请求；配置detach保留等待、永久detach完成并清引用。receipt ledger仅关联owner handle并主线程once投递，不能分配generation/revision。engine ack须requestId、revision、engine身份都匹配，owner仍同一stopped状态且无lease/新工作/unknown才可锁内摘取并主线程锁外destroy；缺ack保留engine。

## 初始状态、HTTP兼容与跨层提交合同

普通冷启动（lib/controller.dart 的 _initCore）在 init 后先 setState，随后 _setupCoreConfig 才提交配置；Android quickStart 同样按 init、state、setup执行。未配置时 getAndroidVpnOptions 没有合法快照。owner必须区分UNCONFIGURED、CONFIGURED和BLOCKED：UNCONFIGURED的setState在operationMutex内按现有部分合并语义校验、深拷贝并保存desiredState，返回STAGED/stateGeneration；旧bool兼容映射true，但不分配configRevision或伪造Applied/options。

首次setup在同一锁内准备不可变initial composite，绑定Core lifecycle epoch、setup载荷及最新desiredState。Go端先做纯JSON、状态和静态结构校验；不得把Mihomo ParseRawConfig当成纯预检。调用ParseRawConfig之前记录ENTERED并分配真实revision；该解析会临时修改General、创建候选资源，且geodata/fake-IP可能有持久副作用。成功从同次提交生成options并标记消费stateGeneration。校验失败保留staged状态允许显式重试；ENTERED后的未知错误保留责任并BLOCKED，不冒充UNCONFIGURED。现有shutdown不清state，缺desiredState的合法低层调用需显式取得并固定原state snapshot，不能假设默认值。quickStart是单次owner操作，不保留旧FFI旁路。

同步commitNativeConfig/commitAndroidConfig携带epoch、expectedRevision、固定mutation kind和canonical载荷；结果包含outcome、phase、epoch、configRevision、options、固定errorCode。prepared载荷不能原地重写base。Go runLock保护revision核验、提交和options快照。startNativeTun/startTUNChecked在锁内绑定reservation、epoch/revision和配置值快照，释放锁后构造并采纳FD，完成后再核对reservation和代次，防止A options配B配置。保持现有peek、global ref、claim和Go FD lease采纳合同，不能换成borrowedFd。任何领取后拒绝仅在FD/ref检查式清理确认后返回rejected，否则unknown。

HTTP PATCH/PUT保留无新headers客户端兼容。route只规范化CanonicalHttpMutation，不直接写setter或ApplyConfig；在不持有Go/listener锁时提交唯一Native owner。缺requestId由owner发行，提供则严格UUID；缺base只在owner首次prepare时读取最后真实Applied revision，提供base严格CAS。活跃VPN变更先撤销旧lease准入并确认旧TUN/监听关闭，再提交、按同次options重建并发布新代；不允许旧lease使用新config。锁序固定为HTTP无锁、Native operationMutex、Go runLock、内部锁。

Go→JNI→Kotlin→JNI→Go回入需真实Android线程附着、CheckJNI及异常清理验证；不能以静态编译代替。ENTERED后客户端断连不取消实际提交。receipt仅保存在同Core lifecycle epoch的有界内存，带容量和TTL，不落盘、不保存config/body；进行中不驱逐，容量耗尽在受理前拒绝。保留期同requestId同digest合并/重放，异digest冲突；epoch换代或过期查询明确miss，不能解释为从未执行。generation、epoch与revision必须独立绑定，不能在新epoch重复revision而省略epoch。

## 检查式监听关闭接线

现有listener.StopListenerChecked已持真实槽位锁、尝试所有登记资源、保留失败对象供显式重试。handleStopListener及action已接入既有检查式入口，只有全部登记资源关闭确认才返回true；isRunning=false仅阻止新监听更新，不证明已关闭。生产handler与action回归使用公开InboundListener，通过正式PatchInboundListeners注册，不创建系统TUN或公网连接；覆盖失败、panic、其他对象继续关闭及重试。此修复不等于整个Go runtime/provider/controller退出，shutdown/suspend的更强合同独立实施。

## Mihomo解析副作用与准备层实施

源码核验：ParseRawConfig中的temporaryUpdateGeneral由executor链接实现，临时设置tunnel/resolver/dialer/inbound/keepalive/geodata/UA/ETag并清接口缓存，defer恢复字段不证明缓存或所有并发观察均回滚。parseIPV6修改传入raw config。proxy/provider及监听构造存在候选资源责任；GEOSITE/GEOIP可能下载或修改geodata，持久fake-IP pool可能触发共享存储恢复/清理。因此在当前上游实现下，进入ParseRawConfig后失败应unknown+BLOCKED，不能声称零副作用rejected。

生产setup准备层首先保持旧签名与成功行为：复制输入后规范化组字段，nil参数固定拒绝，以局部candidate接收parse结果，解析成功后才发布currentConfig/currentRawConfig。失败保留旧配置与原TestURL，输入canonical载荷不可被parseIPV6或组规范化修改。DefaultTestURL若用于解析默认组，须仅在runLock保护的解析期间暂存并在失败时恢复；这仅证明该字段恢复，不是整个解析事务回滚。准备过程责任与实际应用发布分开，为统一Go提交复用，不能把此层独立称为owner接线完成。

初始提交的纯静态validator先拒绝可确定的格式、缺字段、重复名/引用和数值错误；不调用constructors/geodata/cache。parse与ApplyConfig均属ENTERED区域；未知结果阻止新start。当前ApplyConfig和provider Initial含仅日志错误，后续真实Applied合同须明确其同步后置条件与未确认外部provider状态。不可通过新增“纯”函数名或mock测试掩盖实际副作用。

## 同步配置接口实施状态

Go同步接口为getAndroidOwnedConfigStatus及commitAndroidOwnedConfig，后者携带epoch、expectedRevision、kind和JSON载荷。kind为setup/update/state/initialComposite四类；回执固定十字段包含lastApplied、attemptedRevision、stateGeneration、配置/阻断标志及同次options。纯解码与CAS拒绝不进入解析；ParseRawConfig前登记ENTERED，进入后的错误保留责任并阻断。未配置state仅暂存不可变desiredState，不改全局或生成options。

JNI新增独立config_jni.cpp并注册构建输入，Kotlin Core保留名称的同步raw方法交严格codec处理。NativeConfigProtocol限制十字段、枚举组合、数字词法、嵌套重复键、Unicode、深度64及16MiB输入，不暴露可变options树。该层没有发布VPN状态。

这些接口尚未接入唯一Native owner；旧FFI/HTTP/quickStart旁路、带epoch/revision的TUN准入、生命周期epoch更新、ledger及Dart完成回执仍为联合接线工作。当前epoch=1仅标识本次Go库加载生命周期，不支持shutdown后的安全换代；实际ApplyConfig/provider后置条件、CheckJNI及设备全路径独立验收。

## TUN准入与真实收尾报告关键路径

现有State bool及Runtime无法区分干净构造失败、部分listener关闭未知或未采纳FD关闭未知。先在生产androidstartup.State增加锁内StartReport，旧bool从同次report派生；报告在输入清理defer结束后捕获Started/Entered/Running及残余resource/lease和固定错误类别。lease指针责任不等同JNI引用释放确认；保留首个资源/输入清理错误并阻止新启动，不能以第二次Close返回nil清洗未知。纯公开Resource替身和关闭计数复现原状态缺口，定向与race验收。

主控独占联合计划/PDEC/回执/聚合文档；Go施工独占state.go与start_report_test.go，红测试后才实现。其后在真实lib_android入口按runLock内reservation、锁外构造及完成后核验绑定epoch/configRevision与FDLease采纳。runLock不能跨Java回调、State收尾、StartOwned或callback drain等待；State完成并释放mu后才进入配置锁核对。Protect/Resolve期间外部同步回入配置/TUN必须禁止并经真实CheckJNI核验，不能把本机替身当作该条件证明。Go报告FD责任与Native最终清理证据分别处理。

候选owner必须调整caller分配revision、Kotlin预置ENTERED、phase重名、FULL/UPDATE载荷模型、borrowedFd及Boolean完成回执；唯一权威来自Go固定回执，同次options需完整校验disableIcmpForwarding等字段。GlobalState/VpnPlugin的既有代次只能成为adapter票据，不能与owner竞争。HTTP/FFI/quickStart收敛及engine ack为后续同一交付关键路径。

StartReport与Shutdown的真实模块已实现并通过红绿回归及独立审阅。输入清理先固化首因，资源关闭未知保留runtime；回调关闭panic及release panic都转换稳定首错，三个回归明确不允许panic越过调用方。全startup race、core和NDK编译通过。该成果只关闭资源报告前置条件，带版本TUN准入、Native owner及整包设备仍在关键路径。

## JNI回调引用释放的完成事实

生产release_object_func使用int完成状态，Go非空callback缺注册函数时拒绝确认，线程附着失败安全短路。checked-release边界：返回1仅在取得有效JNIEnv、没有待处理异常、DeleteGlobalRef调用结束且任务附着线程完成分离时；0表示尚未执行删除，2表示删除后或线程收尾未知。Go收到未确认必须固定失败并由OnceLease/State的现有panic收口粘滞保留责任，不重试数字FD或删除可能已释放的引用。所有动态Protect/Resolve入口须处理附着失败并拒绝socket/返回空结果。

JNI生产桥、cgo签名、线程helper为同一串行施工包；公开JNI函数表直接通过真实registerCallbacks取得生产release函数，对正常释放、预存异常、DeleteGlobalRef异常、已附着/临时附着、附着失败、分离失败及null对象进行red/green，不启动JVM/业务网络。编译必须使用同一Go生成头，旧头不得掩盖ABI变化。独立审阅后由主控执行fixture、既有JNI负例及新NDK共享库/链接，真实CheckJNI另验。禁止修改JNI授权或读取凭据。可回滚本包源码且保留已有APK/候选。

TUN构造时可能调用Protect/Resolve，不能持Go runLock：回调不得同步提交配置/启停TUN或等待统一owner；在实际owner接线阶段将此约束纳入adapter，并做真实JVM线程与CheckJNI验证。仅改变线程helper不能证明回入死锁已解决。

runLock不能跨Java回调、TUN构造或回调drain等待。带版本TUN准入须在runLock内发行配置reservation并捕获值快照，随后释放锁构造；reservation/活跃TUN期间配置mutation拒绝或由唯一owner先收口，再在同锁完成代次核验和最终发布。旧FFI/HTTP mutation也必须收敛，单独保留当前snapshot而无reservation不能证明版本一致。此限制为后续联合接线的必验合同，当前JNI收尾包不声明已实现。

线程finish失败保存本Go库生命周期的JNI桥cleanupUnknown，不能只把protect/resolve结果转换0/空串后遗忘附着线程责任。后续checked release即使删除调用结束也返回2，State保留未知并阻断新代。C resolve缺函数返回nullptr，与malloc返回约定一致；固定异常清理禁止ExceptionDescribe原文。

Checked JNI释放桥已闭合：release_object_func为int，非空对象0表示未Delete、1表示合法Delete调用无异常且任务finish确认、2表示后置或已有线程责任未知。C空对象不Delete返回0；Go nilcallback是本地无义务成功短路。Go实际调用仅精确1接受，其余经现有OnceLease/State受捕获panic保留失败，不越C ABI。线程helper只在EDETACHED附着，处理空env，分离失败atomic sticky；Protect/Resolve异常短路并保留owned字符串约定。17个真实生产回调的公共函数表ASAN场景、9个既有JNI故障及17个配置桥场景通过；Go State/race及同次Android ABI链接通过。实际JVM/CheckJNI、preclaim全清理回执、reservation和owner接线尚未完成。

## 配置预留模块实施状态

协调器已实现锁内 reserve/finishStart/finishStop：epoch/revision/pointer 身份匹配，同次 options 复制，预留期间 commit 在 ENTERED 前拒绝；正常启动必须同时证明 resource、lease 与 running，清理未知永久保留责任，干净失败和确认停止解除。旧回执不得释放新预留。六项回归、全 core CGO0 和 Android ARM64 核心编译通过；独立审阅发现的缺 lease 条件已用单独红绿关闭。core race 因离线 CGO 依赖缺失未启动。lib_android/JNI、配置旁路、Native codec 错误码和 owner 接线仍为下一关键路径；模块没有对设备发布运行状态。

NativeConfigProtocol 已支持配置预留和 TUN 清理未知的固定错误码，并保持严格 phase/blocked/configured/version 组合。真实生产 parser 公开 JSON 红绿通过。TUN入口、旧配置接口收敛和唯一 owner 接线仍需完成。
