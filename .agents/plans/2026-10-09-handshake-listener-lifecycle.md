# 公共握手监听器任务与待交付连接收尾

## 前置事实与范围

HTTP/SOCKS/Mixed的Reality包装使用common/net.handleContextListener。现有Accept循环退出时关闭conns，但握手goroutine可能仍阻塞或向该通道发送；Close不关闭正在握手的raw socket，也不等待任务。先修复这层真实工厂，保留lazy启动、返回net.Conn类型及成功交付语义。已经由Accept交给消费者的连接由外层owner负责，不能用该前置任务关闭完整协议或VPN验收。

## 串行实施

主控独占common/net/listener.go和同包回归；core/go.sum补齐内核已锁定testify版本的go.mod摘要，使用官方校验缓存，不改模块版本或go.mod。关闭准入与任务Add、pending连接登记同锁；结果通道传递内部责任记录，Accept在同锁中提交真实连接交接，send本身不转移归属；取消及Close真实资源，握手任务完成后才关闭结果通道和done。失败或panic关闭未交付原对象及返回包装对象，conn+error也保留两类责任，nil+nil拒绝；输出固定诊断，logger异常不扩散。实际Close通过逐资源异步账本执行，固定一秒总预算覆盖资源Close和任务退出；未完成Close复用当前任务，不并发重试相同对象。Close失败或预算未完成返回未知并保留责任，显式重试可在任务退出后确认。原始Accept自然失败同样撤销准入、取消并关闭待交付资源，唯一发布者等待所有握手退出后结束结果通道。不可比较net.Conn不作为map键，保留真实动态类型。关闭失败与任务退出要分别核验，聚合已关闭+未知不能清洗未知。

## 验收与回滚

先用真实loopback复现Read阻塞、未退出任务误报成功、待交付send/连接泄漏，再覆盖懒启动关闭、并发Close、关闭错误、panic与logger异常、cancel/Accept竞争和正常交付仍可用。Go race、同模块监听回归、核心编译分别验证；独立原生Agent只读评审设计并在施工后串行复核。只处理任务文件，不安装APK、不切换运行macOS候选、不改生产或系统网络。HTTP/SOCKS/Mixed外层accepted/HTTP pipe任务、全部协议与UDP以及Android完整owner/ACK仍按总计划推进。

## 已执行结果

旧实现三项真实TCP回归失败并检出通道race。20项握手回归及共用模块race通过，SOCKS/Mixed/Reality仅编译、无专门测试。核心完整CGO0回归通过，独立Android ARM64 c-shared编译及四个16KiB加载段验证成功。独立终审无剩余P1/P2。完整外层协议收尾、Android唯一owner/ACK和设备有效VPN继续按总计划集成；未安装APK、切换macOS候选或修改生产。
