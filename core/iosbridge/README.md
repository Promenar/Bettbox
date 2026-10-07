# iOS 公开包流与内嵌 Mihomo 核心

组件使用锁定的 sing-tun v0.4.22 / gVisor 接口，将裸 IPv4/IPv6 包交付真实 Mihomo listener。core/lib_ios.go 是 iOS 主 core 的 C ABI，编译条件为 ios && cgo && with_gvisor。运行路径没有 Dart VM、桌面进程、私有 KVC 或 utun fd 依赖。

## 生命周期

1. bettbox_core_action 的 initClash 初始化，data 是现有 InitParams 的 JSON 字符串；home-dir 必须是绝对路径，由容器应用指定 App Group 核心目录。
2. setupConfig 交付现有 SetupParams，必须先停止核心。系统设备、监听端口、外部控制器、进程发现与自动资源更新均关闭；规则、节点、provider 和 selected-map 保持原模型。
3. 原生扩展完成 NEPacketTunnelNetworkSettings 后调用 bettbox_core_start。网络设置 JSON 包含 mtu、capacity、ipv4-address、ipv6-address、dns-hijack；地址/DNS/MTU 必须与 NE 一致，IPv6 地址必须与配置启用状态一致。
4. Runtime 通过 NewWithTun 创建真实 Mihomo listener，经 gVisor Start 与 Adapter Activate 成功后才发布运行状态，再允许读取 packetFlow。
5. 原生停止读循环，再调用 bettbox_core_stop；listener 先关闭协议栈、再关闭 Adapter。停止可重复调用。shutdown Action 还清理配置和日志订阅。

启动参数示例：

```json
{"mtu":1480,"capacity":256,"ipv4-address":"198.18.0.1/30","ipv6-address":"","dns-hijack":["any:53"]}
```

## C ABI

- bettbox_core_action(data, length, timeoutMs)：现有 Action JSON，data 保持现有 JSON 字符串协议；返回 ActionResult JSON。
- bettbox_core_start(data, length, timeoutMs)：网络设置 JSON；返回 startListener 的 ActionResult。
- bettbox_core_stop(timeoutMs)：返回 stopListener 的 ActionResult。
- bettbox_core_status()：仅在完整 Activate 成功时为 1，开始停止时变为 0；查询不等待生命周期锁。
- bettbox_core_lifecycle()：无锁读取 0 已停止、1 启动中、2 运行中、3 停止中、4 失败；status 为 0 不等于停止已经完成。
- bettbox_core_packet_push(data, length)：在返回前复制裸 IP 包，不保留原生指针。
- bettbox_core_packet_poll(data, capacity, version)：非阻塞回包；capacity 至少为 MTU；version 为 4/6，原生映射成 AF_INET/AF_INET6；空队列返回 0。
- bettbox_core_event_poll()：非阻塞取得日志/消息 ActionResult；空队列返回空字符串。
- 每个返回的 char 指针都必须调用 bettbox_core_free 释放。

包接口负数：-1 参数/包错误，-2 已停止，-3 队满。Action 请求上限 1 MiB，回复上限 4 MiB；事件最多 64 个，单项不超过 64 KiB。超时限制 1–30000 毫秒，默认 10000 毫秒。

SerialRPC 同时只允许一个控制操作。调用超时后后台操作保持令牌直到真实回复；新控制操作可以返回忙，不累积更多后台任务。长时间 provider 操作可能暂时阻止停止或配置，原生应有限重试并按实际状态显示。启动和关闭的底层 listener 操作没有及时完成承诺；独立原子生命周期和 Adapter 快照保证状态及包接口不会因该操作等待生命周期锁。在线 updateConfig 仅允许不涉及设备、监听和权限的字段；其它变更使用停止、完整配置、启动。地理资源更新由容器应用管理。iOS 单次测速直接使用独立超时调用，不进入共享 batch 的永久历史结果表。

## 包与关闭边界

IPv4/IPv6 校验包含声明长度、截断和 MTU；IPv6 jumbogram 不支持。入包、回包、gVisor 输出队列分别有界，单队列配置预算不超过 8 MiB；这不是扩展驻留内存承诺。队满不阻塞原生调用；协议栈回包循环队满时丢弃当前包。纯 io.Reader 模式被拒绝，避免与端点竞争。

关闭取消读取并释放队列包引用，排空使用非阻塞选择，避免并发读者抢走最后一个包后形成死锁。NewWithTun 强制 gVisor，禁用自动路由、设备探测、自动重定向、GSO、fd、接口绑定及系统 DNS blacklist。普通 New 保持既有平台行为；失败初始化和 Start 失败均关闭已创建资源。Runtime 只在完整启动后暴露 Adapter。

## 验证与制品

主控登记执行位置、稳定源码后执行：

```sh
cd core
go test -mod=readonly -tags with_gvisor ./iosbridge
go test -mod=readonly -race -tags with_gvisor ./iosbridge
```

测试覆盖裸包边界、队列所有权、真实 Mihomo listener 注入、端点双向交付、错误启动、并发停止、含包读取/关闭竞争及 RPC 超时/异常令牌恢复。

macOS 使用已有 Go/Xcode 工具链：

```sh
python3 scripts/build_ios_core.py --output build/ios-core-candidate
```

脚本构建完整 core 主包，生成 device arm64 / simulator arm64 分离静态库及 BettboxCore.xcframework，模块名 BettboxCore。每个 SDK 分别执行 clang modules 与 Swift import typecheck。不 tidy、不安装、不签名、不覆盖已有目录。回执包含构建前源码与模块锁哈希、HEAD、相关工作树状态及制品/头文件/modulemap 哈希，结束时比较来源状态；漂移则失败。

代码链路或静态库构建均不代表系统 VPN 验收，回执保持 vpn_ready: false。原生 PacketTunnel 工程、签名、系统授权、真机流量、后台/资源使用和发行验收独立完成。

接口来源：

- https://github.com/MetaCubeX/sing-tun/blob/v0.4.22/stack_gvisor.go
- https://github.com/MetaCubeX/gvisor/blob/3cc44cf9ac22/pkg/tcpip/link/channel/channel.go
