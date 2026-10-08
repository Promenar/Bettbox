# Android 覆盖安装恢复与停止意图

目标：SDK36 覆盖安装保持用户停止意图，并允许更新前已确认运行会话按原流程恢复。BootReceiver 的开机自启语义保持独立。

已验证事实：a21276f 普通停止后保留数据安装会出现运行计时及 WIFI|VPN；PackageReplacedReceiver 在 SDK36 无条件请求 start。运行状态仅驻内存，停止锁属于资源清理屏障。独立只读审阅发现首次速度通知在熄屏时可能提前返回，而 performStartCore 把 Unit 返回当作前台完成。

关键路径及文件所有权由主控串行持有：
1. services/BaseServiceInterface.kt、BettboxService.kt、BettboxVpnService.kt、ForegroundPublication.kt 与 plugins/VpnPlugin.kt：前台发布返回 Boolean，首次速度通知未完成时基础通知兜底，同代实际成功才发布 START。夹具先复现熄屏或未发布却响应成功的旧决策，再验证成功、拒绝和异常边界。
2. 独立资格存储：缺失/读取异常默认拒绝，仅同代 Core 与前台 START 完成后授予；普通停止（包括 IDLE 提前返回、权限撤销）同步撤销，智能暂停不新增或撤销资格。持久撤销失败必须回报未确认，不能用内存读回声明跨进程成功；专属资格存储允许确认删除作为撤销兜底，无法确认则保留阻断与错误事实。
3. receivers/PackageReplacedReceiver.kt：SDK36 的资格和停止锁读取均明确允许、锁内检查后才启动。无标记旧版本默认不恢复。BootReceiver 不参与更新资格判断。
4. 更新 scripts/check_android_vpn_work_gate.py 与公开 JVM 夹具，真实 release Kotlin 编译、独立串行复审；源码候选完成后统一正式 APK 构建，不为每个文件改动重复全量构建。
5. 同源设备覆盖安装：从未运行/普通停止、已确认运行、首次 PENDING、智能暂停与权限撤销；每个场景核对 UI、前台服务和活动 NetworkAgent 的组合 transport。测试恢复原设置并普通停止。

权限及边界：只处理非秘密恢复资格与应用生命周期，不读取凭据、不改变 VPN 授权、不修改系统网络/开机自启设置，不碰用户 .video_agent。唯一 owner/typed Go ACK、有效代理 HTTPS 和三端服务端业务仍需独立验收。

验收入口：PDEC validate；生产 JVM 协程夹具；批准的 compile-android-stop-response-adapter；批准的正式 Android 构建/保留数据安装；ARM64 Pixel_7 adb UI 树驱动观察。Dart 未改时复用同摘要的278项回归，不把夹具或编译替代设备行为。

回滚：按精确源码提交恢复本工作包的文件与契约摘要；保留 a21276f APK 和设备回执；不删除其它配置、凭据或旧 debug 包。失败资格存储不得升级为正常更新恢复成功。
