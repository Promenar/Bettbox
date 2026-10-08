# Realm HTTP 监听生命周期

## 目标与已验证缺口

Hysteria2 Realm 的多地址构造会立即启动 HTTP Serve；后续绑定失败没有清理前面的资源。Listener.Close 只关闭监听端口，没有持有 HTTP Server，既有连接仍可继续请求；reaper 取消后没有等待退出。该协议保留于完整 Android listener owner，不删除协议规避验收。

## 实施所有权

主控串行修改 listener/hysteria2_realm/server.go 及同包测试。Listener 持有真实 HTTP Server、Serve/reaper 任务、handler 准入与任务等待。关闭先撤销 handler 准入并取消 reaper，再关闭真实监听 socket；任何未知错误直接返回并保留责任，避免 HTTP Server 内部不可取消的 Accept 等待。监听关闭确认后再关闭 Server、等待已准入任务，最后清理 session。聚合错误只移除已关闭分支，不消除其它失败。多地址构造失败执行同一关闭链，关闭未知时保留部分 Listener 并返回错误。正常监听和 HTTP 业务协议保持。

原生独立只读审阅者复核错误、部分创建和并发关闭。新的停止合同不证明所有协议的握手、QUIC、UDP runtime 或文件证书 watcher 已退出；全部协议资源组、转发 runtime、TUN、配置与 completion/ACK 仍按唯一 owner 总体计划集成。

## 验收与回滚

以真实 loopback socket 先复现关闭后 keep-alive 仍可请求、多地址失败遗失端口；修复后验证已有连接断开、端口重绑、Serve/reaper/已准入 handler 完成、并发重复关闭及 session 清理。注入关闭错误须返回失败并保留对象责任，不据此释放整体 owner。Go race 测试及核心包编译使用本机既有 PDEC/离线依赖，不使用公网、设备或生产服务。回滚仅恢复任务差异；不安装新 APK 或更改系统代理。
