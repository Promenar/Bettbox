# Android 代理节点与 TUN 启动验收

## 目标与当前事实

使正式 Android 客户端通过真实代理节点完成 HTTPS 请求，并准确处理启动失败、保护失败及退出。源 APK 为 e7b5a87，公开证据见 docs/validation/2026-10-07-three-platform/android-vpn-path-validation.json。地域列表、系统 VPN 建立、直连模式请求及停止恢复已验证；代理请求失败尚未归因。

23 个订阅节点为12个AnyTLS及11个Hysteria2；TCP端点均可连接，AnyTLS证书均可信，订阅密码不等于开发用户UUID。NoSLA辅助Mihomo只有VMess，不能作相同协议对照。Kotlin同名protect的候选字节码调用捕获函数，没有递归。

## 关键路径与所有权

主控负责协议探测工具、PDEC执行项、Go/JNI/Kotlin合同、设备验收及文档；独立只读审阅者复核实施后差异和完整合同，不并行修改共享文件。

1. 用同版本核心对少量订阅AnyTLS节点做受限协议探测，再覆盖Hysteria2。原始订阅/凭据仅在受保护本机进程内存与可信目标传递；请求目标固定公开HTTPS端点，证书校验保持开启。报告只含协议、节点匿名序号、HTTP状态及固定错误类别。隔离监听只绑定回环，不改变系统路由、服务配置或上游账户。
2. 对比Android和同版本独立核心。独立核心成功时定位Android配置包装、protect及UDP路径；共同失败时核验CloudBridge上游授权、额度和协议配置。TCP/TLS成功不能替代协议认证；无结果不得猜测付费或自动续费。
3. 独立复现三项审阅缺口：配置尚未就绪时启动重入tunLock；listener启动失败仍保留runTime/START；protect false或异常未到达dialer。先建立失败测试，再改造Go→C→JNI→Kotlin的明确结果合同，固定错误枚举，避免地址和原始异常进入日志。
4. 失败时收尾callback、FD、listener、hook及VPN服务，保证唯一释放者；停止和late callback覆盖重试/代际边界。正常启动必须以实际listener成功为依据。
5. 冻结源码后构建正式候选、验签、安装回读，再验证真实节点请求、VPN覆盖、失败关闭、停止及冷启动。直连模式通过不代替代理节点成功，模拟器通过不代替真机或16KiB设备验收。

## 影响文件与验收

预期实施范围为 core/lib_android.go、core/android_bride.go、core/androidstartup/、android/core/src/main/cpp/、android/core/src/main/java/com/appshub/bettbox/core/、android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnPlugin.kt 及必要服务薄桥接、关联测试与文档。跨语言ABI必须整体一致；确定具体入口与所有权后才修改。

使用现有Go/Kotlin/Flutter测试和正式构建驱动，不增加不受控系统工具或重复构建。探测入口需登记PDEC、锁定源与依赖、限制预算和输出；错误逻辑必须有真实失败/通过回归。完整Flutter回归在客户端/桥接变化后运行；只读证据更新复用相同代码的192项结果，不重复运行。

## 回滚与边界

失败保留当前正式APK及证据，候选不公开上传，不支付/充值或修改上游账户；原始秘密不入仓库、日志、模型或审阅报告。仅停止本任务拥有的进程和转发，保留用户 .video_agent。测试模拟器最终保持VPN停止；用户既有Mac系统代理与其它项目模拟器不改动。


## 协议对照执行事实

受限同源探针7项Go测试、执行器3项测试及两轮独立审阅通过；真实抽样2AnyTLS/2Hysteria2均失败，后者固定分类为authentication，尚不能归因密码或额度。服务器ClashMeta构建两个协议时从relayTag提取密码覆盖面板参数；下一步只读核对同步源节点与订阅输出的认证字段一致性，再判断上游条件，不自动续费或修改生产账户。安全脱敏回执见registry。Android失败处理三缺口仍需实际复现及修复。


## 原生FD与回调合同

实际Service通过establish.detachFd移交描述符，不保留原FD；因此不采用“Service原FD+Go dup”假设。Kotlin在JNI入口前持有局部FD租约，取消时关闭；JNI入口开始后无条件移交Go，Go在NativeTun采纳前负责关闭，采纳后由Listener唯一关闭。JNI global ref由OnceLease、完整callback由CallbackGate保护；保护失败必须经Kotlin Boolean、JNI(I)Z、C整数结果及Go RawConn.Control外层错误完整传回。配置快照锁释放后才取得生命周期锁；Kotlin代际锁不得跨native调用。

sing_tun新增受限入口NewWithNativeFDOwnership(options,tunnel,adopted,additions...)，返回Listener、初始化错误及首次cleanup错误；保留原Stack选择。内部在l.tunIf登记后同步adopted；失败关闭成功时返回nil Listener，失败关闭错误时保留部分Listener与首次错误，禁止第二次Close掩盖。普通New及NewWithTun保持当前行为。此阶段文件所有权仅server.go与native_fd_ownership_test.go；主控在接线冻结后登记PDEC和验收，施工不执行系统网络调用。

当前生产启动函数的4个实际函数体在公开替身依赖夹具中执行：listener失败仍返回成功/提交时间、未配置fd0仍提交、配置nil的正FD重入锁不能返回，3项均实际失败。此证据覆盖控制流，未编译Android ABI，不替代后续JNI/设备验收。Kotlin建立后取消的detached FD泄漏及旧代保护读可变Service为源码事实，须补实际回归。


监听器所有权入口已完成8项回归与独立复审，未接Android ABI。Kotlin租约还需在native调用异常时确知JNI是否领取FD；优先评估JNI通过本代局部FDLease.claim领取并记录标记，Kotlin finally仅关闭未领取FD，杜绝异常后double-close。所有权合同测试不能替代实际构造采纳路径；接线验收须覆盖采纳前失败、采纳后失败及system/gvisor/mixed选择。


## 生产接线执行包

Go施工独占core/lib_android.go、core/android_bride.go、core/tun/tun.go、core/androidstartup/state.go及关联新增测试；主控独占Core.kt、TunInterface.kt、JNI core.cpp及Kotlin FD租约。接口保持startTUN(fd,callback)布尔结果，stopTun新增布尔结果，protect C回调返回int（JNI(I)Z）。Core对应用层startTun(fd,protect,resolver)返回Boolean；JNI私有入口通过Kotlin本代FDLease领取描述符，finally只关闭未领取FD。生成libclash头与ABI由冻结后正式驱动生成，不手工改生成头。

Go配置只在runLock下复制必要primitive字段，释放后才进入State生命周期锁。原生FD租约在进入State前创建并在所有提前拒绝路径收回；未采纳关闭失败保留首错并阻止新代启动。CallbackGate先关准入后等pin，再释放一次JNI引用；闭门handler作为拒绝socket保护哨兵，成功关闭后才清空，未知关闭保留。监听器初始化期间必须可保护socket，resolver不读取未同步listener指针。

验收：现有State/CallbackGate回归、新增输入关闭失败及RawConn.Control保护false/异常逻辑回归；JNI生成头和Kotlin真实编译后做候选APK构建、安装回读、失败启动/停止/重新启动设备验证。有效上游恢复后才验证代理出口；三栈有效constructor采纳路径仍需有界失败夹具与设备证据。

## 智能停止完成确认

生产 smartStop 的两条 MethodChannel 入口须等待同代 nativeGate 关闭和 SUSPENDED 状态提交；关闭、挂起监听释放、JNI 挂起调用异常或旧代提交失败均返回 false，保留阻断责任。Dart 两包装器仅接受 true，调用方不预置 isSmartStopped，未确认时不得清空运行时间或流量。恢复启动资格和唯一 owner/ACK 保持后续联合验收范围，不以该阶段替代代理流量验证。主控独占 VpnPlugin、ServicePlugin、Core.suspended、Dart 两包装器和两调用方、相关回归/PDEC/文档；独立 Agent 只读串行复核。先运行实际包装器 red，再执行 gate/JVM、release Kotlin、完整 Flutter 与 analyze。
