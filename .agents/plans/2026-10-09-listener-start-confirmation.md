# Dart监听启动真实回执传播

## 范围与事实

公共ClashCore.startListener忽略检查式启动的false；后台ClashLibHandler直接调用void FFI后返回true，失去Go动作结果。Go action已有带请求ID、方法、code与bool的真实启动回执。主控串行持有lib/clash/core.dart、lib/clash/lib.dart、lib/state.dart、listener_stop_completion.dart及关联三个回归文件；现有业务配置、协议、权限和线程调度保持。不要将回执解析视为Android完整owner/ACK或VPN完成。

## 实施与验收

先以实际公共ClashCore接口复现false被忽略，再将后台包装器切换为同次Go invokeAction回执；与停止共用严格解析。拒绝false、错误ID/方法/code、畸形数据；传输异常保留。公共及GlobalState后台路径拒绝继续推进。真实Go FFI与完整Flutter回归、静态检查、独立串行审阅分别验收。原生前台发布、计时、旧后台直接调用及completion/ACK仍由完整owner计划联合处理。

## 边界与回滚

不安装APK、不改macOS运行候选、不处理凭据、不改生产。只回滚指定源码；已有运行资源不可用legacy调用清洗。总体三端与服务端全路径目标保持未完成。

## 验证结果

旧公共入口false回归失败；修复后12项定向测试、完整305项Flutter测试通过，完整回归启用真实Go动态库与生产Handler启动/停止。当前Go C ABI独立构建成功；Flutter analyze无问题。串行独立审阅无新增P1/P2。GlobalState服务路径副作用与设备尚未联合验收，提前计时及IPC/quickStart未await入口仍待完整owner接线。
