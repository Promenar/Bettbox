# macOS supervisor 接线计划

目标是将已验证的身份链和唯一Core回收模块接入实际业务管道与客户端。Android和macOS优先交付，iOS保留开发版及发行研究；本计划不增加管理员权限、共享控制listener或付费服务。

## 固定合同

Core和helper使用固定App产物与最终身份清单，先签两个产物和清单，再签宿主。helper角色由native入口选择，从自身SDK MainExecutable取得App；封存产物发行器保留Core文件FD，spawn前只做文件重检，SDK调用放到独立有界worker。一个helper仅创建一个Core；回收仍仅由SupervisorLifecycle处理。

私有阶段帧为4字节little-endian非零长度加严格UTF8，最大4096。固定紧凑JSON顺序：`supervisor_ready`为type/protocol/generation；`prepare_core`增加launch；`core_ready`增加launch/pid。protocol=1，generation为1..Int64.max，launch为native产生的小写UUID，PID只是定位值。所有重复、额外字段、非canonical字节、错代次、半帧或超限均拒绝。helper argv仅允许固定`--owned-supervisor-v1 --generation G`。

helper先发布supervisor_ready；只有收到prepare且固定自身/父属/seal核验完成才启动Core。Core SDK链worker通过后发布core_ready。host native完成链核验后发送原Go HELLO，helper验证首帧并转发；实际Go ACK完整提交给host后才进入business。spawn之前起算同一5秒Core启动预算，不能在SDK/阶段/ACK之间重置。初始helper核验单独采用5秒预算。SDK worker不写FD、不spawn、不wait或signal；结果只进入有界mailbox，由主loop检查意图/期限后消费。

Go帧和业务动作保持现有协议；helper每方向至多一完整数据帧，business最大10MiB。为避免Dart IOSink在第二个满帧上阻塞close，增加私有`relay_credit`控制帧，字段顺序为type/protocol/generation/sequence；只有上一host帧已完整写入Corestdin并且credit已完整发给host，才允许读取下一host帧。Go ACK给予第一个business发送许可；每个business帧消费一个许可，credit严格连续。此确认只证明管道写入，不证明业务完成。Go result仍独立异步到达；Core输出只接受原protocol/generation/result envelope，不能伪造helper控制帧。

relay使用nonblocking poll，每次读取只填当前帧所需字节；stdout背压不阻断tick/EOF/worker取消。即使输入暂停也观察HUP/error；明确验收Darwin满pipe关闭行为。一个数据帧之外最多一个4096以内credit，不建立无界queue。实际握手完成、输出EOF和子进程退出分别处理；未知资源保留owner，不能kill helper代替Core完成。

宿主ABI：reserveSupervisorLaunch(generation)返回native launch关联值及固定已核验helper路径；bindSupervisor(launch,generation,pid)返回native opaque handle；bindCoreChain(handle,pid)返回另一个opaque handle；recheckCoreChain(handle)在native复核；revokeLaunch(launch,generation)立即撤销同代权限；confirmStopped(launch,generation)核对已记录出生消失。Dart不提供身份字段、UID、路径、哈希或签名；handle只查native表，不能用于重建authority proof。native kernel读取必须区分明确消失、不同出生及未知错误，不能把所有异常当退出。

## 文件所有权与验收

主控负责Identity封存发行器、Owner借用端点接口、宿主native ABI、构建与最终接线。独立helper工作包只写指定候选目录中的codec/poll/主程序及测试；独立Dart工作包只写指定候选目录中的Session/ABI适配/测试。共享actual、PDEC、聚合文件及治理由主控独占。高风险实现完成后串行独立审阅，再登记PDEC实际编译/执行。

必要证据为：生产codec负例；真实SDK/helper/Core链；exactSHA Go HELLO/ACK和有效业务动作；Dart其它Process并发退出；EOF/满pipe/半帧/迟到SDK/取消和真实TERM/KILL；同一Dart Process exitCode与native出生消失；SC事务正确设置及仅持有值恢复。生产签名和安装包在上述接线完成后验收，不能以独立fixture代替完整发行。

回滚仅弃用未启用的模块；macOS新会话不能静默退回共享控制socket或与Dart竞争reaper的路径。停止未确认时保留旧Process和native记录，不创建新helper。

## 执行证据与应用接线边界

生产helper、Host六ABI与DartSession源码已纳入；32项原生步骤、最终host定向回归、17项Session、155项Flutter全量测试和静态分析通过。真实签名矩阵在公开framed Core上确认握手、credit/result和停止；篡改与错误ID拒绝。回执为 `docs/validation/2026-10-07-three-platform/macos-supervisor-integration-validation.json`。

独立审阅发现的commit跨截止、SDK后出生变化与HUP背压缺口已修复，实际输出缓存取消和HUP残留输入红例得到复现。Core未取得出生记录时保持未知；未发行reservation的预检失败只有SDK退出后释放。host主动EOF正常完成仅证明已捕获的本代Core回收，不承诺取消后的未来业务结果；缓存或未读输入丢弃固定失败。

Runner工程已纳入Host/Identity源码及固定通道，真实Go Core与生产helper/native host独立进程链已验证；helper打包与最终宿主开发签名已验收；ClashService的macOS传输/RPC路由已接入，SC消费尚未接入。应用验证需在相同冻结版本确认完整签名seal、真实动作/结果、IOSink背压与退出、系统代理事务和账户有效流量。Android继续整包JNI/Service/配置所有者接线与正式APK验收；iOS保留开发版及发行方案研究。

封装验收：生产helper快照编译、签后FD核验、Xcode复制和最终bundle源/锁一致通过；Core/helper先签与清单绑定，10个framework及宿主开发seal按内到外完成。成功清单链接写入红例失败后修复为排他no-follow发布并经独立回审。下一关键路径为SC路由与正常应用安全存储签名；不以整包签名代替运行证据。

真实Flutter探针入口为 `integration_test/macos_supervisor_probe.dart`，通过生产MethodChannel、Session、helper与固定真实Go Core连续完成两代getIsInit。每代16个公开true子进程分别确认exit和双管道EOF；Session停止确认helper exit0、控制EOF与native出生消失，最终宿主exit0。未确认所有者保留且禁止新代次。驱动明确冻结两个探针输入摘要，独立签名候选只用于探针，正常App按完整文件摘要恢复。50项macOS工具测试、158项Flutter测试与静态分析通过；回执为 `docs/validation/2026-10-07-three-platform/macos-flutter-supervisor-validation.json`。

探针ad hoc签名不携带entitlements，不加载账户、配置或系统代理。正常候选保留Release钥匙串权利；实际系统AMFI曾拒绝带受限entitlements的ad hoc探针，即使严格验签通过。ClashService、SC事务、Keychain冷启动及有效订阅流量尚待联合验收；完整可分发应用尚未交付。

## macOS应用请求接线

主控独占 lib/clash/service.dart、message.dart、supervisor_session.dart 与新增 supervisor_rpc.dart。RPC每代最多8个在途请求、已接收待交付结果总预算16MiB；单事件1MiB，直接调用既有监听器；异步批次最多32个/序列化16MiB，监听器注册最多32个；失败通知与全部任务settled独立，未知消费者阻止新代，不加入异步broadcast队列。每个请求固定单调ID、精确方法及五键Go结果匹配，发送失败、超时、畸形/重复/未知回包撤销整代，正常超载只拒绝新增请求。停止立即拒绝请求并取消计时器，unknown owner保留Session，不创建新helper。

ClashService仅macOS走生产Session；其它平台保持既有实现。macOS没有socket、直接Core Process或legacy fallback，preload必须等待已完成握手。正常restart串行停止确认后才创建新代次；shutdown/destroy走同一停止通道。RPC交付前等待发送与回包双确认，统一deadline和独立cancel覆盖挂起sender；结果仅保存在可撤销item中。RPC返回继续使用既有ActionResult/Result类型；不把Dart状态或endpoint作为SC授权。旧startListener在owned模式被Go明确拒绝，原生专用HTTP/SC入口须联合接线后才构成可用代理。

验证：新增真实生产RPC测试覆盖匹配、超载、内存限额、发送失败、超时撤销、事件同步消费、重复回包、撤销后迟到；Session停止通知测试；Flutter全量测试及静态分析。独立审阅后在真实Flutter探针使用RPC两代getIsInit与并发child，明确源码摘要、停止及原App恢复。回滚仅还原本节涉及文件，保留未知Session所有权，不启动旧macOS控制通道。

macOS应用接线：ClashService通过生产Application/Session/RPC管理启动、重启、请求、就绪和停止，不创建旧控制socket、不直接启动/终止Core、不进行legacy fallback。含就绪等待最多8个请求，重启排队最多8个；RPC结果序列化预算16MiB，单事件1MiB，异步事件批次最多32个且序列化预算16MiB。事件监听器的Future返回值可观察，失败与全部结束分别跟踪，未知任务不能被Coregone清洗。回执 `docs/validation/2026-10-07-three-platform/macos-application-supervisor-validation.json` 确认真实Flutter两代Application/RPC、32个公开child及native停止，181项Flutter测试与静态分析通过；正常main的登录、SC与有效流量另验。

## 预检失败的原生停止证据

目标：固定 helper 身份预检失败且没有发行 reservation 时，允许实际 Application 在原生 worker 结束后重试。新增 `confirmPreflightStopped(generation)` 只读取当前 native ticket：代次匹配、worker 已结束、ticket 已撤销且停止、reservation 未发行、helper/Core 出生与 proof 均不存在时返回 true。此结果不授予 SC 权限。已发行 reservation、迟到 worker、错代次、未知状态均返回 false；Dart 不根据 owner getter 清理失败。

文件所有权：主控串行修改 HostSupervisorAuthority、Session、对应 Swift/Dart 测试和受影响文档/PDEC。验收：先保留真实失败测试；执行登记的 host 测试、Session 测试、Flutter 全量与 analyze；独立审阅未知状态保留与迟到时序。回滚仅还原上述文件，不启动 legacy 通道。不涉及系统配置、签名密钥、支付或用户数据。

验收结果：保留1项真实失败红例，修复后184项Flutter测试、analyze与host生产typecheck/交错fixture通过，独立审阅未发现P1/P2。真实Application/Session重试采用native/transport fixture；签名探针及正常main未执行本版。
