# HTTP、SOCKS、Mixed TCP监听生命周期

## 实施依据与范围

三个真实工厂仅关闭入口，accept循环和已接入处理器没有联合收尾。SOCKS握手/UDP Associate及CONNECT进入阻塞Tunnel.HandleTCPConn；普通HTTP另建pipe、异步route及Peek watcher，Upgrade也建pipe。公共握手监听已有实际资源Close账本与任务、准入、失败重试和迟到对象责任。以同一底层责任机制采用真实协议，不新建未启用helper，不删除协议或连接复用能力。

## 关键合同与所有权

主控串行持有common/net公共监听机制及新增scope、HTTP server/proxy/client/upgrade/startHTTPRoute、SOCKS tcp、Mixed工厂和协议回归。真实accepted连接保持动态类型；外层handler在同一准入锁登记，Close先撤销、取消并关闭原对象，等待实际handler及已登记route/watcher。HTTP pipe两端在创建后同步登记，启动goroutine前任务Add；正常会话结束也取消并释放内部管道。未知Close或未退出任务保留资源引用，后续显式Close才能确认。共享生命周期账本维持总预算与单调轮次，不复制一个弱化关闭实现。

HTTP任务承载上下文、pipe创建和async路由/读取由本会话scope提供，SOCKS直连HandleTCPConn仍阻塞于真实delegate；UDP全局runtime不在TCP owner内伪造完成。认证、元数据、TLS/Reality包装、地址和传统入口保留；默认HTTP入口与专用credential-blind入口的认证边界不改变。HTTP Transport内部read/write/dial任务以及证书watcher没有公开join API，必须从锁定源码取证，不能以本层handler退出替代全部依赖任务退出。

## 验收与回滚

实际工厂TCP CONNECT/SOCKS连接在Close后仍可读写、handler未退出误报成功先写红回归；再验证真实HTTP请求/Upgrade/keep-alive、SOCKS4/5/UDP Associate、Mixed分流，TLS未完成握手、阻塞delegate与失败重试、正常动态类型与认证回归。Go race及全core回归、Android ARM64 c-shared编译分别执行；施工后独立审阅。仅任务相关源码、文档、PDEC、回执和HLG，不触碰.video_agent、凭据、APK安装、生产业务、macOS候选或系统网络。代码回滚保持既有提交，已产生的资源责任须真实收束。总体三端/服务端发行目标保持未完成直至全路径证据齐备。

## 设计复核约束

scope主handler结束时先同锁撤销准入并取消，再清理；active计数包含全部子任务，全部退出与资源确认之后才能prune。NewPipe在同锁准入检查之后创建并登记，迟到Dial不先创建；任务拒绝不能降级到legacy go。EOF回调经scope同步准入，不接受撤销后Peek；owned Upgrade使用账本替代AfterFunc，TLS握手继承owner context。scope与listener双层撤销在Add之前同锁检查；正常/失败清理均继承单调round。保留keep-alive与用户变化认证，失败不伪造Close确认。

## HTTP逐请求认证缺陷

真实HTTP/Mixed复用连接中先成功认证两用户，第四个错误用户请求仍进入路由并返回200。旧trusted在连接级保持true，认证失败不能撤销。以当前请求authenticate返回resp为空作为准入，逐请求独立核验，合法用户切换沿用CloseIdleConnections隔离复用。真实红回归两条路径已复现，使用仅进程内生成的测试口令，不输出或落盘。

## 执行与剩余范围

7项工厂、5项scope、1项接口拒绝及既有20项握手回归通过，相关模块完整race和核心完整CGO0通过。HTTP逐请求认证真实HTTP/Mixed两条红回归已修复；合法请求/用户变化、keep-alive、Upgrade与SOCKS4/5及TCP UDP控制连接通过。最终PDEC有效后Android ARM64 c-shared编译及四个16KiB加载段核验成功，独立终审无新增P1/P2。拒绝fallback动态观测仅有界50ms，源码同时复核不降级。Transport和证书watcher内部join、其它协议/UDP和完整Android owner/ACK及三端/服务端全路径未完成，运行APK/macOS候选与生产未修改。
