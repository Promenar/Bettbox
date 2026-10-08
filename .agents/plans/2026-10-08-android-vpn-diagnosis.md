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
