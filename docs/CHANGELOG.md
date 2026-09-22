# 版本变更记录 (CHANGELOG)

## [Unreleased] - 邀请返利客户端 (2026-09-22)

- 账户页增加邀请返利入口，可读取并主动创建邀请码，复制网站注册链接与邀请码，显示邀请注册二维码。
- 展示 Xboard 注册人数、累计佣金、确认中佣金与可用佣金；币种由服务端提供，返利计算与结算保持在后台。
- 分享网站不可用时降级为邀请码；异常统计响应不展示为零；登录状态变化使页面数据失效。
- 补充七种语言资源以及邀请模型、接口、页面交互测试。
- 建立共享业务主线与独立平台验收路线；iOS 需要 Packet Tunnel/IAP，已有 iPhone，开发者团队待准备。
- 测试面板的网站地址配置为 `https://cloud.microsoftnexushub.top:8443`；App 实际读取配置、生成邀请链接与网页预填已验证，配置旧值已备份。
- 在测试面板精确镜像的无网络、只读临时容器中，通过真实 HTTP Kernel/业务服务/结算命令验证邀请归属与返佣；使用内存业务库和模拟付款完成状态，未产生真实交易。公网注册提交、下载引导、支付及并发结算仍需独立验收。
- 桌面收银使用系统浏览器，Android 控制器在重绘时复用，初始收银地址只接受 HTTPS；增加失败反馈及平台回归测试。
- 补齐 macOS Keychain entitlement，将 Podfile 与 Xcode 最低系统版本对齐当前 Xcode 27 SDK 的 macOS 12 要求，并更新 Pod 锁文件。
- 增加非发布的桌面构建验证脚本、Windows GitHub 标准 Runner 工作流与 PDEC；保留既有发版入口。

## [Unreleased] - feature/m1-account-subscription (2026-09-08)

### 新增特性 (Features)
- **Xboard 商业版账号与订阅闭环**：
  - 支持内嵌式登录、注册、密码找回流程与 Auth Token 安全持久化（`SecureStore`）。
  - 支持套餐订阅信息自动同步与到期/流量监测。
  - 支持应用内商品列表（`Store`）、下单购买与历史订单查询。
- **高可用域名自动切换与救援**：
  - 引入 `DomainScheduler` 域名池健康探测与无感连接层故障轮换机制。
  - 支持远端引导源（`BootstrapClient`）更新入口域名池。
  - 支持订阅 Profile URL 主机名（Host/Port）热替换。
- **节点商业脱敏与地域智能包装**：
  - 实现 `NodePackager`：自动将节点清洗归入所属国家/地区分组。
  - 支持组内会话保持负载均衡 (`load-balance` with `sticky-sessions`) 或自动优选 (`url-test`)。
  - 首页支持商业版精简地域卡片与延时挡位聚合显示。
- **多语言适配**：
  - 补充 `en`, `zh_CN`, `zh_TC`, `ja`, `ko`, `ru`, `fa` 七种语言关于账号、订阅、订单及地域命名的国际化资源。

---

## [1.19.0+2026081601] - 2026-08-16
- 基于 Mihomo (Clash Meta) 内核的基础开源版。
- 多平台网络调试及规则分流客户端，支持 Android、macOS、Windows、Linux。
- 提供可视化设置、Widget 小组件、自定义主题与分流 UI 适配。
