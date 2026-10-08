# Android 智能恢复完成确认

目标：两条 smartResume 通道只有同一启动意图完成 RUNNING 提交后才能成功；Dart 拒绝 false/null，并在回执与同一会话均确认后提交运行显示。

事实：service 通道忽略 handleSmartResume 返回值并无条件 true；Vpn 通道只返回请求接受。管理器和后台恢复预先清除停止状态。

主控所有权：VpnPlugin.kt、ServicePlugin.kt、SmartResumeAwaiter.kt、生产 Kotlin 夹具及运行脚本、lib/plugins/service.dart 与 vpn.dart、smart_stop_completion.dart、smart_auto_stop_manager.dart、main.dart、对应测试/PDEC/文档。序列为客户端失败 red、原生有界完成等待和身份检查、Dart 提交修复、JVM夹具及Kotlin编译、Flutter全回归、独立只读复审和候选提交。

边界：启动请求拒绝立即失败；等待同一 intent RUNNING 和 generation；投递到主线程时再次核验；换代或终态失败不成功；30秒等待到期取消准确意图并返回失败；挂起标记只在同代启动提交时清除；失败不提交 Dart 计时，旧回执不覆盖新会话。此回执是原生生命周期确认，不等于带身份的 Go engine ACK 或有效代理流量。

验收：PDEC validate，Dart失败断言red/green，公开JVM协程夹具，真实 Android release Kotlin 编译，完整Flutter真实GoFFI回归及analyze，独立复审。新APK设备和快速交错另验。回滚仅本工作包源代码，不改凭据、系统网络或服务端。

完成判定：RUNNING/PENDING仍等待前台收尾，RUNNING/START才构造回执；控制器持有未确认启动来源，绑定断开和启动异常也沿用该来源。主线程确认后释放来源；普通停止取消来源。生产快照决策与来源控制器必须由同源JVM夹具覆盖。
