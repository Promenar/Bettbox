# Android 启动请求拒绝传播

## 目标与边界

ServicePlugin 必须返回 VpnPlugin.handleStart 的真实受理结果。Dart Service.startVpn 遇到 false 或空回执必须抛错，阻止 GlobalState.handleStart 在被拒绝后继续持久化运行偏好及开启更新任务。true 仅表示请求已接纳，不表示 TUN、监听器或有效 VPN 流量已完成。

该修复是唯一原生所有者联合采用的前置项，不替代完整接线。提前设置 startTime、先行启动监听器、不可变配置及资源 completion/ACK 继续由 android-single-owner-adoption 计划处理；拒绝不能通过无身份停止清洗可能存活的资源。

## 所有权与验收

主控串行修改 ServicePlugin.kt、lib/plugins/service.dart 和 test/plugins/android_start_admission_test.dart。测试先证明旧 Dart 包装器在 false/null 后继续调用，再验证拒绝阻断、等待响应、接纳返回和平台错误保留。独立审阅核对原生返回与 Dart 调用方，避免把受理解释为连接成功。使用既有本机 Flutter/PDEC 验证入口；原生完整编译和设备受理场景需单列证据，不由 mock channel 测试推定。

## 回滚

回滚任务变更前保留差异；不得修改运行中 APK 或启动新的应用会话，不触碰签名秘密及系统代理。macOS 黑屏仍待真实窗口核验，锁屏不能作为修改渲染设置的依据。
