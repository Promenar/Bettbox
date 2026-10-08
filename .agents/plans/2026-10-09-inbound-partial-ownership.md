# 命名监听部分创建责任与失败传播

## 目标与事实

所有20种命名协议共用 PatchInboundListeners。现有 Listen 错误不登记对象，替换和删除忽略旧对象 Close 错误；相同配置无法区分可运行对象与失败的部分对象。核心启动和配置更新也没有收到监听应用失败。这些路径必须保留真实责任，不能用空登记或配置相同推定成功。

## 串行实施边界

主控修改 listener/listener.go、stop_checked.go、新增同包回归及核心 common.go/hub.go/android_config.go/lib_ios.go 和对应回归。增加检查式 Patch 入口：登记先于 Listen，错误或 panic 保留对象并标记未确认；替换/删除关闭失败保留旧对象；任一未确认命名资源存在时不构造新对象，显式检查式停止确认后清除责任。已确认对象可按相同配置复用。旧 void 入口使用相同实现并输出固定失败信息，不吞原生状态。

核心 updateListeners 接收错误，启动请求失败不报告 true；setup/update 在发生副作用后失败不能声称成功或回滚，Android coordinator 保留 entered unknown。iOS 更新适配保留真实错误。general ReCreate、转发runtime、完整listener组和typed ACK按唯一owner总计划处理；不能用命名协议登记回归证明全部资源已退出。

## 验收与回滚

先通过实际loopback绑定复现 Listen 错误丢失、旧Close失败被覆盖/删除；再验证错误/panic保留、同配置失败不复用、全组未知阻止新增、成功停止后重建、已确认相同配置复用、Close去重及真实Realm部分对象接线。核心公开配置/动作测试检查错误传播和原生coordinator未知状态。Go race、核心回归和Android ARM64编译分别留证；不安装APK、不改生产或系统代理。非施工Agent串行复核。回滚只恢复任务相关差异并保留失败资源，不能使用无身份清理未知连接。


## 实际验收

原路径4项loopback登记回归失败，旧核心3项生产传播回归失败。独立审阅发现相同配置新增别名、保留别名替换、替换中断和删除中断4项责任缺口，均通过真实socket及不幂等Close建立红绿；统一对象canonical、保留引用与对象级清除后11项命名race、5项检查式关闭、核心完整CGO0测试及Android ARM64编译通过，最终独立复审无新增P1/P2。成功setup全局ApplyConfig只完成静态传播审阅和编译，未做副作用集成测试。公开证据位于 docs/validation/2026-10-07-three-platform/inbound-partial-ownership-validation.json；完整三端目标未完成。
