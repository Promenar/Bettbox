# macOS 框架错误诊断

## 事实与目标

macOS候选已到达首帧回调，锁屏阻止窗口观察。AppController.init覆盖FlutterError.onError并仅在debug输出堆栈，release吞掉框架错误，不能用无日志推断组件正常。目标是在runApp之前安装固定框架失败日志，控制器初始化不得将其覆盖；不输出异常、堆栈、library或账户资料，不改变渲染器和系统代理。

## 串行实施与验收

主控处理lib/common/framework_error_reporter.dart、lib/main.dart、lib/controller.dart及隔离回归。先把现有策略提取到真实共用入口，使用FlutterError.reportError建立固定输出缺失和输出异常传播的红回归；再在全部构建模式输出固定失败标记，并保护诊断sink异常。静态核验真实启动接线，Flutter回归和analyze、macOS开发候选构建单独留证。独立原生Agent只读审阅，源摘要、签名和日志固定计数用于验证新候选；锁屏仍不得称为黑屏修复或可用发行。

## 资源与回滚

PDEC本机Apple开发操作；输出捕获到私有600文件，仅非LLM程序提取固定计数。不改钥匙串或全局设置，不安装依赖或启用系统代理。旧包和运行会话在候选封装完成之前保留；应用退出通道确认旧宿主/子进程退出后才切换，失败不使用强杀。无法窗口观察时保留候选，目标继续处理独立授权工作。


## 验收记录

旧共用策略2项红回归，修复后3项定向回归含真实组件构建失败通过；Flutter完整298项通过1项跳过，最终analyze无问题。最终macOS完整开发构建源/锁未漂移，正常退出旧宿主和两层子进程后保存旧包，新包Apple Development嵌套签名与严格验签通过。新宿主6081、supervisor6087、core6089启动并到达首帧，观测时0框架失败标记。实际Release未主动注入错误；界面工具仍锁屏，黑屏根因与可见窗口未验。公开证据macos-framework-error-validation.json，旧包可回退，三端目标未完成。
