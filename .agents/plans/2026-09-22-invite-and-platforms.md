# 邀请返利与平台扩展实施计划

日期：2026-09-22。状态：邀请客户端候选已通过本地验证；测试入口、后台分享域名与邀请码预填已验证；账户业务闭环待验收；平台扩展为规划。

## 目标与已确认范围

- 用户已确认沿用 Xboard 后台的奖励计算、归属和结算；客户端提供邀请分享与收益展示。
- 二维码与链接指向带邀请码的网页注册页；网页绑定邀请关系并承接客户端下载。
- 邀请页面复用现有 Material 3、CommonScaffold、Material Card 与 qr_flutter，不引入新的组件体系。
- macOS、Windows 执行现有工程的能力盘点；iOS 给出独立隧道工程与商业链路路线。
- 不在客户端计算奖励或修改佣金余额；提现、佣金转余额、运营规则调整、服务端部署及商店发布不属于该功能范围。

## 已验证事实与接口基线

- 初始工作树干净，分支 `feature/m1-account-subscription`，源码基线 `9cbf17b`。
- `lib/views/account/register_page.dart` 与注册仓储已支持 `invite_code`；用户模型已有 `commission_balance`。
- `pubspec.yaml` 已有二维码渲染依赖；邀请 API 与页面已由提交 `d8eba05` 实现。
- Xboard 上游核对版本：`cedar2025/Xboard@4f48e61a2cbc6db5338872b6bdb45ef954ec1256`。上游契约不是部署实例联调结果。
- `GET /user/invite/fetch` 返回 `codes` 与 `stat`。`stat` 依次为注册人数、累计有效佣金、确认中佣金、基础返佣比例、可用佣金；金额单位为分。
- `GET /user/invite/save` 有创建邀请码的副作用，仅由用户点击触发，不在页面加载或自动重试时调用。
- `GET /guest/comm/config` 提供 `app_url`；`GET /user/comm/config` 提供币种和符号。
- 页面链接必须来自面板公开网站配置；禁止把 API 的当前域名或订阅 URL 当成分享域名，禁止附带认证信息。
- `invite/details` 上游采用无 `status` 的分页包络；首期收益采用统计接口，避免为未纳入范围的明细接口放宽通用包络校验。

## 实施顺序与文件所有权

所有写入由主控串行完成；独立审阅者仅审阅实现和验证证据。

1. 新增 `lib/xboard/invite.dart`：严格模型解析、站点链接构造、邀请仓储和与会话隔离的页面数据。
2. 扩展 `lib/xboard/endpoints.dart` 与 `xboard.dart`，仅增加邀请相关能力。
3. 新增 `lib/views/account/invite_page.dart`，并在 `account.dart` 已登录区域接入入口。
4. 更新七种 `arb/intl_*.arb` 并通过现有 intl_utils 生成 `lib/l10n/`。
5. 增加模型、HTTP 契约、失败路径与页面交互测试；完成独立审阅后修正问题。
6. 同步产品、架构、变更记录和本计划；通过 HLG append 写入事实链。

## 用户行为和边界

- 已登录账户可打开邀请页，查看注册人数、累计佣金、确认中佣金与可用佣金。
- 有可用邀请码时直接复用；没有时展示主动创建按钮；创建期间防止重复提交。
- 链接与二维码使用同一个经过校验的 URL，支持复制链接及邀请码。
- 网站地址缺失或不符合安全要求时保留邀请码和收益展示，明确提示暂不可生成分享链接。
- 网络失败显示可重试状态；解析失败不伪装成零收益；创建失败不自动重放写请求。
- 页面请求与会话绑定，登出或切换账户时不展示上个账户的收益、邀请码或异步回包。
- 金额保留分的精度，不在客户端重新计算佣金；展示币种来自服务端。
- 网页注册之后的下载引导由实际面板主题提供；需在受控账号上单独验证注册归属，不能以二维码渲染成功替代业务验收。

## 验收

- 单元测试覆盖字段顺序、零佣金、异常响应、有效与失效邀请码、金额与链接编码、缺失和不安全站点配置。
- HTTP 测试覆盖接口方法、鉴权、无自动创建、创建后重新获取邀请码、创建失败不重试。
- 页面测试覆盖加载、错误、空邀请码、重复点击、复制内容、二维码数据一致及账户切换清空。
- 执行本地已有 Flutter 工具链的轻量分析、国际化生成、全量 `flutter test`；不触发平台安装包构建或发布工作流。
- Android 实机扫码→网页邀请码预填→注册绑定→受控订单返佣为部署验收，需实际站点与测试账户环境；不制造真实付款或佣金流水。

## 平台扩展路线

| 平台 | 源码现状 | 实施重点 | 独立验收 |
| --- | --- | --- | --- |
| macOS | 原生工程、系统代理、内核授权与 DMG 构建入口存在；CI 已列 arm64/amd64 | 验证商业版账号、订阅、邀请与支付；Keychain、TUN 授权、睡眠恢复；签名与公证 | 双架构构建及实机连接、DNS/IPv6、退出恢复代理、升级与卸载 |
| Windows | 原生工程、Rust HelperService、核心签名流程、EXE 打包存在；CI 已列 amd64/arm64 | 商业版全链路、DPAPI、提权服务、系统代理和 TUN、浏览器支付返回 | 对应架构构建及实机连接、服务重启、升级卸载、网络恢复 |
| iOS | 无 ios/；.gitignore 明确忽略该目录；setup.dart 无 iOS target；内核非 Android 分支走桌面进程 | 新建 Runner 与 Packet Tunnel Extension；App Group/Keychain、隧道 IPC、内核桥接、后台恢复；沿用 PRD 已决 Apple IAP | 真机隧道、锁屏、Wi-Fi/蜂窝切换、DNS/IPv6、恢复购买、票据校验及退款撤销 |

iOS 的 Flutter UI 和 Xboard 数据层可复用，但当前内核启动模式不能直接沿用。先验证最小真机隧道，再接完整商业功能。IAP 服务端必须将经验证的 Apple 交易接入幂等订单与返佣流程，并处理退款撤销；客户端支付完成事件不能作为奖励依据。

## 开发执行与分发

- 当前 `.pdec/contract.yaml` 缺失，inspect 返回 `state=missing`。
- 现有 CI 由 `v*` tag 触发并含发布步骤；平台验证应先设计无发布入口，不能用发版 tag 充当普通构建检查。
- Apple 开发工具链保留 Mac；Windows 专属验证考虑 Main。公开仓库的确定性构建优先评估已有 GitHub Runner；按项目公开性和实际主机能力完成 PDEC 适配后执行跨平台构建。
- `setup.dart` 的 distributor 准备流程含 clean、pub upgrade、global activate，不能把完整打包入口当成只读检查命令。
- iOS 的开发者组织资格、Network Extension capabilities、签名配置、分发地区及 IAP 商品与服务端桥接属于发布前置事实，尚未核验。

## 回滚

邀请实现只新增客户端能力，保留既有注册手工邀请码路径；可通过还原本任务提交撤销。无数据库迁移，无后台奖励规则修改。平台扩展规划不改变当前构建或发布行为。

## 一手资料

- [Xboard 邀请控制器](https://github.com/cedar2025/Xboard/blob/4f48e61a2cbc6db5338872b6bdb45ef954ec1256/app/Http/Controllers/V1/User/InviteController.php)
- [Apple Packet Tunnel Provider](https://developer.apple.com/documentation/NetworkExtension/packet-tunnel-provider)
- [Apple Network Extension 部署说明](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Apple VPN App 审核要求](https://developer.apple.com/app-store/review/guidelines/#vpn-apps)

## 验证记录（2026-09-22）

- 使用当前已有 Flutter 3.44.9 / Dart 3.12.2 缓存环境，未新增依赖。
- `flutter test --no-pub`：91 项全部通过，邀请相关新增 19 项。
- `flutter analyze --no-pub` 覆盖邀请数据层、页面、账户入口、端点、导出与两个测试文件：无问题。
- 七种 ARB 均包含新增 19 项文案，intl_utils 生成成功。
- Widget 测试验证 320px 与 1.6 倍字号无溢出；测试渲染图位于忽略目录 `.test/invite-page.png`（模拟数据）。
- 使用 macOS Vision 从该渲染图独立解码二维码，结果与复制链接一致；这不代表实机网页注册归属已验收。
- 原生 Sol medium 独立只读审阅后修正确认中佣金的小数分展示，120.5 分显示为 1.205；最终无剩余 P0/P1/P2 发现。
- 测试面板 `https://cloud.microsoftnexushub.top:8443/` 经普通域名连接、直连及指定源站 IP `170.106.143.23` 三条路径验证，首页与公开配置接口均返回 HTTP 200，TLS 校验通过。浏览器注册页可预填链接中的邀请码。
- Python 默认 User-Agent 请求公开配置返回 403，换为 curl 标识返回 200；Bettbox 实际 Dio 客户端同一路径返回成功。这证明请求客户端差异可复现，不能据 Python 的 403 推断服务宕机；服务端具体拦截规则尚未查证。
- 公开配置 `app_url=https://cloud.microsoftnexushub.top:8443`，域名入口与指定源站入口均返回该值。生产代码 XboardApiClient 与 buildXboardInviteLink 实际读取配置并生成测试邀请链接，浏览器注册页正确预填测试标记。
- 用户已授权开发阶段可配置项按需调整。测试面板通过原生 `admin_setting` 接口只更新 `app_url`，非目标设置的前后散列一致，使用 `octane:reload` 重载 Web 工作进程后生效。旧值回滚记录保存在服务器 `/opt/xboard-test/config-backups/app-url-20260922T060534Z.json`（权限 600）。
- 配置调整使用既有 SSH 认证，不读取或暴露认证材料；未创建真实邀请码、未提交注册、未生成付款或佣金流水。登录态接口、邀请码归属和返佣到账仍待受控测试账号验收。
- 桌面端与 iOS 未执行安装包构建、实机 VPN 验证或发布。
