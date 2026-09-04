# Bettbox 商业版 PRD —— 对接自建 Xboard 面板的专用代理客户端

| 项 | 内容 |
|---|---|
| 版本 | v0.5（草案，待评审） |
| 日期 | 2026-08-29（M0 实测回写 2026-08-30） |
| 变更 | v0.5：M0 联调基线达成——测试面板上线硅谷机，§5 API 事实表经实测冻结（响应包络/auth_data/订阅响应头/注册字段/试用套餐闭环），修正"核心不含支付插件"结论（仓库自带 plugins-core）；新增 `docs/bootstrap/domains.json` 引导源雏形。v0.4：Q2/Q4/Q8 已决 + F-NODE-6/7 地域权限分层与热更。v0.3：Q7 已决（iOS 接 Apple IAP）。v0.2：GPL 路线、品牌/包名、iOS 同步立项、F-NODE 地域包装 |
| 基线仓库 | Bettbox 1.19.0+2026081601（Flutter，Mihomo 内核，GPL-3.0） |
| 文档目的 | 收敛产品需求、明确边界与验收标准，给出初步实现方向 |

> 事实标注约定：文中【已核验】= 已读仓库源码或 Xboard 上游源码确认；【假设】= 未经验证、待评审或联调确认；【开放】= 需要产品/运营决策。

---

## 1. 背景与目标

### 1.1 背景

Bettbox 是基于 FlClash 早期版本重构的多平台 Mihomo(Clash Meta) 客户端，已具备完整成熟的内核管理、VPN/TUN、订阅导入、可视化配置能力。但它是一个**通用客户端**：用户自备订阅链接，无账号体系、无购买支付闭环。

本项目目标是在 Bettbox 基础上裁剪、增强出一个**专用商业客户端**，绑定自建 Xboard 面板运营：

1. **账号体系内嵌**：App 内直接注册、登录、找回密码，不依赖网页。
2. **购买充值内嵌**：App 内浏览套餐、下单、拉起支付、查询订单、余额充值。
3. **订阅全自动**：登录即自动生成/更新订阅，无需手动粘贴链接。
4. **域名自动切换**：面板主域名被封禁/更换时，客户端能自动发现并切换到新域名，订阅与 API 全部无缝迁移，用户无感。
5. **节点商业包装**：界面只呈现"地域 + 状态词"，地域自动聚合、组内负载均衡对用户不可见（§3.6）。

### 1.2 目标与非目标

**目标（In Scope）**
- Android 8.0+ 为首发平台，Windows / macOS / Linux 桌面端同步支持（跟随现有工程能力）。
- **iOS 同步立项**：复用上游 Flutter 跨端能力（UI 与业务层最大程度共用），iOS 侧新建 NetworkExtension 隧道工程、签名体系与商店合规（工程量与风险见 §7.3 M-iOS、§9 R9）。
- 对接单一个自建 Xboard 面板（版本以部署实例为准，API 以 v1 为主、v2 按需）。
- 订阅、账号、支付、域名切换、节点地域包装五条主链路的完整闭环。

**非目标（Out of Scope）**
- 通用客户端能力全面开放：商业版以"账号订阅"为主形态；手动导入订阅的代码与能力**完整保留**，但 UI 不引用（见 F-SUB-6）。
- 多面板/多机场聚合、Clash 订阅转换服务等面板侧能力。
- 面板侧（Xboard 服务端、支付插件、引导配置源服务）的开发：本 PRD 只提出**运营侧配合要求**（§6.5、§7.4），服务端建设由运营方立项。

---

## 2. 用户与核心旅程

**目标用户**：购买本服务订阅的终端用户（以移动端为主）。

**旅程 A —— 新用户（获客→付费→使用）**
1. 安装 App，首次启动展示品牌引导页与隐私政策。
2. 进入"商店"浏览套餐（未登录即可看，价格与套餐来自 `guest/plan/fetch`）。
3. 选购套餐 → 弹出注册/登录（注册仅需邮箱+密码，视面板开关可能需要邮箱验证码/邀请码）。
4. 下单 → 拉起支付（二维码 / 收银台跳转）→ 支付结果轮询 → 成功。
5. App 自动生成订阅、自动选中并一键开启连接。

**旅程 B —— 老用户（换机/重装）**
1. 安装 App → 登录 → 自动拉取订阅与套餐状态 → 一键连接。

**旅程 C —— 域名被封/更换（关键差异化场景）**
1. 用户正常使用中，面板主域名被墙/运营方更换。
2. 客户端 API 或订阅请求失败 → 判定域名异常 → 从域名池轮换下一个入口。
3. 同时从"引导配置源"拉取最新域名列表，持久化更新域名池。
4. 订阅 Profile 的 URL 热替换为新域名并自动刷新；若 VPN 正在运行则自动重载配置。
5. 用户无感或仅在极端情况下看到一次性提示。

---

## 3. 功能需求

优先级定义：P0 = MVP 必须；P1 = 第二批；P2 = 远期。

### 3.1 F-DOMAIN 域名自动切换（本产品核心卖点）

**F-DOMAIN-1（P0）域名池**
- 客户端维护 API 入口域名池：`内置初始域名列表` + `远端引导源下发的域名列表` 合并去重。【已核验：当前仓库无任何域名池概念，需新建】
- 所有 Xboard API 请求与订阅请求统一走"当前活跃域名"，由统一的 BaseURL 提供者注入，禁止业务代码散落硬编码域名。

**F-DOMAIN-2（P0）健康探测与自动轮换**
- 探测路径：`GET /api/v1/guest/comm/config`（轻量、无需鉴权）。
- 触发时机：①App 启动；②任何 API/订阅请求出现**连接层失败**（DNS 失败、连接超时、TLS 错误，不含 4xx/5xx 业务错误）；③定时（默认 6h，可配置）；④从后台回前台且距上次超过 30 分钟。
- 失败处理：当前域名连续 2 次连接层失败 → 标记 unhealthy → 切换域名池中下一个候选 → 异步刷新引导源。全池失败 → 进入"救援模式"（见 F-DOMAIN-4）。

**F-DOMAIN-3（P0）引导配置源（运营侧配合，详见 §6.5）**
- 启动时与每次域名异常时拉取引导源 JSON，内容包含：当前有效 API 域名列表、备用引导源地址、最低可用客户端版本、公告链接。
- 引导源本身必须多源冗余（CF Workers / 独立备用域名 / DNS TXT 记录），客户端按序尝试。
- 新域名列表拉取成功后**持久化**并立即生效，无需重启 App。

**F-DOMAIN-4（P0）救援模式（兜底）**
- 全部域名不可达时：明确提示"服务入口已变更"，提供：①一键重试；②手动输入新域名；③扫码导入新订阅/新入口；④打开公告页查看最新入口。
- 手动输入/扫码获得的新域名写回域名池并触发验证。

**F-DOMAIN-5（P0）订阅联动热切换**
- 域名切换生效时：自动改写当前账号订阅 Profile 的 URL host 部分 → 触发订阅更新 → 成功后若 VPN 正在运行则静默重载配置，失败保留原配置并按重试策略退避。
- 订阅 URL 原则：**以服务端下发的 `subscribe_url` 为权威**，客户端只做"替换 host"操作，不自行拼接路径。【已核验：`user/getSubscribe` 与 `user/resetSecurity` 返回服务端生成的 `subscribe_url`】

**验收标准（摘要）**
- 关闭主域名模拟（hosts 劫持/断开）后，客户端在 ≤60s 内（含下次请求触发）自动切到备用域名并恢复功能，全程无需用户操作。
- 引导源返回新域名后，域名池持久化，冷启动直接使用新域名。
- 切换过程中正在播放/下载的 VPN 连接不中断（订阅重载成功前不触碰运行中的内核配置）。

### 3.2 F-AUTH 账号体系

**F-AUTH-1（P0）注册**：邮箱 + 密码（密码 ≥8 位）+ **邮箱验证码（必填**，`passport/comm/sendEmailVerify` 先行发送）+ **邀请码（选填**，用于后续 aff 邀请返利活动，留空可注册）。【已决 Q2；验证码/邀请码的请求字段名仍需 M0 抓包冻结，见 §5.3-1】
**F-AUTH-2（P0）登录/登出**：登录返回 `token`、`auth_data`（Bearer 凭据）、`is_admin`。多设备会话管理 P1（`getActiveSession`/`removeActiveSession`）。
**F-AUTH-3（P0）找回密码**：`passport/auth/forget`（email + email_code + password）。
**F-AUTH-4（P0）会话保持与校验**：启动时 `user/checkLogin` 校验，token 过期/失效 → 静默登出并引导重登，已下载订阅数据保留只读展示。
**F-AUTH-5（P1）安全存储**：token 存入系统安全存储（Android Keystore / macOS Keychain / Windows DPAPI，引入 flutter_secure_storage），禁止明文 SharedPreferences。【已核验：当前工程持久化只有 SharedPreferences 整块 JSON，需新增安全存储依赖】
**F-AUTH-6（P1）快速登录**：`token2Login` / `getQuickLoginUrl` 深链回跳 App（网页面板 → App 免密），依赖 app_links 深链基建扩展 scheme。【已核验：工程已内置 app_links 深链导入订阅】

### 3.3 F-PLAN 商店与套餐

**F-PLAN-1（P0）套餐列表**：未登录可浏览（`guest/plan/fetch`），展示名称、价格（月/季/半年/年等周期）、流量/速率/设备数限制、库存售罄态。
**F-PLAN-2（P0）下单**：已登录用户选择周期 → `user/order/save`（plan_id + period，可选 coupon_code）→ 生成待支付订单。
**F-PLAN-3（P1）优惠券**：下单前 `user/coupon/check` 实时校验并回显折后价。
**F-PLAN-4（P1）续费/升级语义**：区分新购/续费提示文案；同 plan 多周期价格展示。

### 3.4 F-PAY 订单与支付

**F-PAY-1（P0）支付方式列表**：`user/order/getPaymentMethod` 动态拉取（支付宝/USDT/Stripe 等取决于面板安装的支付插件，App 端不硬编码）。
**F-PAY-2（P0）收银**：`user/order/checkout`（trade_no + method）。响应 `type/data` 渲染：
- 二维码型（type=0，如支付宝当面付）：App 内渲染二维码 + "我已支付"。
- 跳转型（type=1，收银台 URL）：Android 内嵌 WebView 打开【假设 A1：需新增 webview 依赖】；桌面端调系统浏览器打开。【已核验：工程当前只有 url_launcher 外链，无内嵌 WebView】
- 免费订单（type=-1）直接按成功处理。
- 未知 `type` 走兜底渲染（`data` 形似 URL 时尝试打开，否则提示联系客服）。
【已核验：`type` 契约 `0`=二维码内容 / `1`=跳转URL / `-1`=免费单已支付，来自上游插件源码（§5.2、附录）；残余不确定性仅在实际安装的第三方插件，见 §5.3-4】
**F-PAY-3（P0）支付结果闭环**：收银页打开后按 3s→5s→10s 退避轮询 `user/order/check?trade_no=`；成功 → 强刷 `user/info` + `user/getSubscribe` + `user/server/fetch` + 地域目录 + 触发订阅更新（联动 F-NODE-7，新地域即时解锁）；失败/超时 → 订单列表可查。
**F-PAY-4（P0）订单列表/详情**：`user/order/fetch`、`order/detail`；待支付订单可继续支付或 `order/cancel`。存在未支付订单时新下单会被面板拒绝，UI 需先引导处理旧订单。【已核验：服务端对未支付订单有互斥限制】
**F-PAY-5（P1）余额充值**：余额支付路径与充值套餐下单（面板侧配置决定），走同一收银框架。
**F-PAY-6（P1）礼品卡/兑换码**：`user/gift-card/*`（Xboard 已内置路由）。
**F-PAY-7（P0，iOS 轨）iOS 内购（IAP，Q7 已决）**：iOS 购买统一走 Apple IAP。
- IAP 商品与套餐周期一一映射（每套餐×周期一个内购商品）；购买完成后由**服务端**完成票据校验（App Store Server API + App Store Server Notifications V2），校验通过后给面板账户入账或直接开通对应套餐，客户端随后刷新用户态。
- 票据校验与入账桥接为运营侧服务（建议以 Xboard 插件实现，见 §6.5-6）；客户端只负责拉起 IAP、收据上送、结果轮询，不做本地信任。
- iOS 套餐定价需计入 Apple 分成（标准 30%，中小开发者计划 15%）并在商店页展示；Android 走自有渠道分发不受此约束（见 R9）。

### 3.5 F-SUB 订阅联动

**F-SUB-1（P0）自动订阅**：登录成功且存在有效套餐 → 自动创建/更新一条受管 Profile（隐藏 URL 细节，用户不可编辑），选中生效。
- 体验套餐承接（Q4 已决）：新注册用户经 Xboard 试用套餐机制默认开通半小时体验套餐（`try_out`，已核验原生支持，运营侧配置见 §6.5-7），体验套餐可访问的节点由运营在面板权限组中管理；正常情况下不存在"无套餐账号"。
- 兜底态保留：若出现无套餐账号（体验套餐被删/接口异常），不报错：首页与商店呈现"开通引导"态（套餐推荐 + 一键跳转购买），已下载的旧订阅数据只读展示。
**F-SUB-2（P0）流量与到期展示**：复用现有 `subscription-userinfo` 头解析 + `user/info`（transfer_enable/u/d/expired_at/balance）双源，首页与"我的"页展示流量环、到期倒计时、套餐名。
**F-SUB-3（P0）到期与临期提醒**：长周期套餐到期前 7/3/1 天、流量 ≥90% 时，启动弹窗 + 首页常驻条幅，一键跳转续费；体验套餐等短周期（<24h）按**分钟级倒计时**处理：剩余 10 分钟起条幅提示，到期后立即切换至续费引导态。
**F-SUB-4（P1）重置订阅**：`user/resetSecurity`，二次确认后更新受管 Profile（旧 token 立即失效）。
**F-SUB-5（P1）订阅自动更新节奏**：保留现有 24h/自定义 autoUpdate 能力，受管 Profile 默认每 6h 更新一次。
- SaaS 自动更新策略（2026-09-04 已决）：配置管理界面隐藏，客户端承担更新责任——登录态：查看订阅卡即刷新（`refreshSubscriptionCycle`，2 分钟节流）+ 前台每 6h 定时 + 启动/支付/域名切换事件触发，面板数据与订阅内容一次拉齐，卡上展示"数据更新于"；登出态：冻结全部自更新（受管 Profile `autoUpdate=false`，面板 API 与域名切换联动均跳过），配置保留可用不断连，重登后恢复并全量同步。
**F-SUB-6（已决）手动导入模式**：手动导入订阅的代码与能力**完整保留**，但 UI 前端不引用（所有入口隐藏），线上形态为纯账号订阅；保留代码便于内部调试与后续策略调整，也与上游代码保持最小分歧。

### 3.6 F-NODE 节点包装与地域聚合（商业包装核心）

商业版不向用户暴露原始节点列表与延迟数值，用户只做"选地域"这一件事。

**F-NODE-1（P0）地域自动聚合**
- 从 Xboard 下发订阅的节点名称解析地域并聚合，识别规则覆盖：emoji 旗帜、中文地域词（香港/台湾/新加坡/日本/美国/韩国…）、英文与常见缩写（HK/HKG/TW/SG/JP/US/KR…）；解析规则表内置，并支持随客户端版本/远端配置更新。
- 解析失败的节点归入"其他"地域兜底，任何情况下不展示原始节点名。

**F-NODE-2（P0）状态词展示（不暴露节点与延迟）**
- 地域列表只展示"地域名 + 状态词"，状态词三档：**流畅 / 正常 / 拥挤**；不显示节点数量明细、不显示任何延迟毫秒值。
- 映射规则（阈值可配置，探测数据仅留在客户端本地）：对地域内节点做周期性 url-test 探测——存在可用且时延 <150ms 的节点 → 流畅；<400ms → 正常；其余（高时延/高丢包/探测失败占比高）→ 拥挤。

**F-NODE-3（P0）地域选择与配置生成**
- 用户只能选择地域；配置生成时把同地域全部节点包装为 mihomo 自动组（每地域一组），顶层选择器由地域组构成。
- 顶层提供"自动（最优地域）"选项且为默认值：按状态词优先级（流畅 > 正常 > 拥挤）自动选择地域。

**F-NODE-4（P1）地域内负载均衡**
- 每个地域组默认 `url-test`：自动使用组内最优节点、故障秒级转移，用户感知为"该地域始终可用"。
- 设置中提供地域级"分流均衡"开关，开启后该地域组切换为 `load-balance`（策略 `sticky-sessions`：同一会话粘滞同一节点，避免 IP 跳变影响登录态类业务），并自动剔除连续探测失败的节点。【已核验：工程内置 mihomo 内核支持 load-balance 与 sticky-sessions（core/Clash.Meta/adapter/outboundgroup/loadbalance.go）】

**F-NODE-5（P0）节点名脱敏一致性**
- 连接页、日志页、代理组等全部界面中，节点名一律以"地域代号 + 序号"（如 HK-01）呈现，不透出机场原始节点命名；地域识别与 F-NODE-1 共用同一规则表。

**F-NODE-6（P0）地域权限分层展示**
- 地域分三类处理：①**当前套餐已授权**（订阅内容包含的地域）→ 正常展示状态词、可选择连接；②**面板存在但当前套餐无权限** → **不隐藏**，展示为锁定态（"受限"标识，不显示状态词、不做探测、不可连接），点击弹升级引导（展示哪些套餐包含该地域）；③**面板完全不存在的地区** → 完全隐藏。
- 机制依据【已核验】：Xboard 节点按权限组过滤（`ServerService` 以 `group_ids` 匹配套餐组），无权限节点**不会出现在订阅与 `user/server/fetch` 返回中**；因此客户端无法仅凭订阅得知"面板还有哪些地区"，"面板存在但无权"的地域必须由运营侧下发目录判定（F-NODE-7）。

**F-NODE-7（P0）地域目录与热更（支付后即时解锁）**
- 运营侧下发"面板地域目录"（全部地区 + 套餐映射关系），客户端据此区分"可连接 / 受限 / 不存在"。下发通道优先级：①Xboard 插件提供的 guest 地域目录端点（实时读面板节点表，零漂移，运营侧建设项见 §6.5-8）；②降级：引导源 JSON 的 `region_catalog` 静态字段（§6.3）。
- **热更时机**：每次启动；每次订阅更新动作（手动/自动）；域名切换成功后；**支付成功/套餐变更后立即刷新**。
- 解锁链路：支付成功 → 强刷地域目录 + `user/server/fetch` + 订阅更新 → 新地域从"受限"转为可连接，全程无重启、无需用户手动刷新，避免"付费后界面节点没变化"。

**实现方向**：受管 Profile 在配置进入内核前经统一"包装转换器"完成——节点名规范化 → 地域分组 → 组类型注入 → 状态词数据源（mihomo RESTful API 的 proxies/delay 数据，仅本地使用）→ 与地域目录合并生成前端地域列表。落点：新建 `lib/xboard/node_packager.dart` 与 `lib/xboard/region_catalog.dart`，或复用现有 JS 覆写管线（flutter_qjs）以托管脚本实现，优先选择可测试性更好的 Dart 原生实现。

### 3.7 F-USER 个人中心与内容

**F-USER-1（P0）我的页**：头像/邮箱、套餐卡（名称/到期/流量）、余额、订单入口、设置入口、退出登录。
**F-USER-2（P1）公告**：`user/notice/fetch` 列表 + 详情；运营可发"域名变更"类公告。
**F-USER-3（P1）工单客服**：`user/ticket/*` 列表、创建、回复、关闭。
**F-USER-4（P1）使用文档**：`user/knowledge/*` 按分类展示。
**F-USER-5（P2）邀请返利**：`user/invite/*` 邀请码/佣金/提现申请（`ticket/withdraw`）。
**F-USER-6（P1）流量明细**：`user/stat/getTrafficLog`。

### 3.8 F-INFRA 基础体验

- **F-INFRA-1（P0）** 新增底部导航"商店/我的"（扩展现有 PageLabel 枚举），连接页保持现有体验为首页。
- **F-INFRA-2（P0）** i18n：全部新增文案走现有 arb 体系（7 语言）。【已核验：arb/ + intl_utils 流水线完备】
- **F-INFRA-3（P1）** 品牌化：品牌名**网穿云**（界面中英并用，英文代称 CloudBreach）；包名 `com.cloudbreach.app`（全英文，不含拼音/仓库/作者字段，与上游 `com.appshub.bettbox` 完全隔离，避免商店冲突与升级误装；首次上架前仍可修改，上架后不可变更）。应用图标、主题色、启动页同步品牌化。
- **F-INFRA-4（P1）** 深链扩展：一键换域链接、一键登录链接、网页收银回跳。

---

## 4. 非功能需求

**安全**
- 凭据仅存系统安全存储；日志（现有 logs 页）禁止输出 token、auth_data、订阅 URL 完整串（脱敏 host+token）。
- 全链路 HTTPS，证书校验不关闭；引导源多源中至少一个支持证书固定【假设 A2：固定策略实施细节实现期定】。
- WebView 收银页禁用第三方 Cookie 共享、限制导航白名单为收银域名。

**隐私与合规**
- 首启展示隐私政策（自建页面，链接由 `guest/comm/config` 下发的 ToS 字段）。
- 客户端不新增任何用户行为埋点上报（保持上游"零隐私收集"承诺，商业化后更须谨慎）。
- 法务：**GPL-3.0 传染性是本项目第一合规风险**，见 §9 R1；境内分发与 VPN 服务运营合规风险由运营方承担，客户端按目标市场要求配置（见 §9 R6）。

**性能**
- 启动路径不得被网络请求阻塞：引导源拉取、域名探测全部异步，UI 先用缓存域名/缓存订阅渲染。
- 域名切换期间内核保持运行；订阅重载失败不闪断现有连接。

**兼容**
- 保持上游工程能力（多平台桌面、Android TV 形态）不被商业化改造破坏；上游更新可继续合并（fork 策略见 §9 R7）。
- Android 8.0+（minSdk 26 维持现状）。

---

## 5. Xboard API 集成规约

### 5.1 通用约定【已核验：上游源码 + M0 实测 2026-08-30】

- Base：`https://<活跃域名>/api/v1/`（v2 端点按需）。
- 鉴权【实测】：注册/登录返回 `data: {token, auth_data, is_admin}`；`auth_data` 自带 `Bearer ` 前缀，请求头原样 `Authorization: <auth_data>`，有效期 1 年。
- 订阅【实测】：`GET /api/v1/client/subscribe?token=<订阅token>` 返回完整 mihomo YAML；响应头 `Subscription-Userinfo: upload/download/total/expire`（total 为字节）、`Content-Disposition: attachment`、`Profile-Update-Interval: 24`（小时，默认模板值）。token 错误 → HTTP 403 + JSON 包络。
- `subscribe_url` host【源码+实测】：面板设置项 `subscribe_url` 优先（**逗号分隔支持多个订阅域名**），未设置时回落到请求 Host（实测经 `127.0.0.1:7001` 拉取即回该 host）。
- 响应包络【实测】：`{"status":"success"|"fail", "message":<中文>, "data":..., "error":null}`；个别端点失败存在省略 `status` 的变体（实测 `order/save` 周期错误仅返回 `{message}`）——客户端解析需同时容忍两种形态。

### 5.2 客户端所需端点清单（已核验自上游路由定义）

| 模块 | 端点 | 方法 | 关键参数/返回 |
|---|---|---|---|
| 引导探测 | `/guest/comm/config` | GET | 无鉴权；ToS、注册开关（验证码/邀请）、应用配置 → 用作域名健康探测 |
| 套餐 | `/guest/plan/fetch` | GET | 未登录套餐列表 |
| 注册 | `/passport/auth/register` | POST | `email`、`password`(≥8)【联调：验证码/邀请码条件字段】 |
| 登录 | `/passport/auth/login` | POST | `email`、`password` → `token`,`auth_data`,`is_admin` |
| 找回 | `/passport/auth/forget` | POST | `email`,`email_code`,`password` |
| 验证码 | `/passport/comm/sendEmailVerify` | POST | `email` |
| 会话 | `/user/checkLogin` `/user/info` | GET | 用户信息：transfer_enable,u,d,expired_at,balance,plan_id… |
| 订阅 | `/user/getSubscribe` | GET | 【实测】`token`、`subscribe_url`、`plan`（嵌套完整套餐）、`transfer_enable`（字节）、`expired_at`、`device_limit`、`speed_limit`、`next_reset_at`、`reset_day`、`u`/`d`；无套餐时返回失败（需兼容） |
| 重置订阅 | `/user/resetSecurity` | GET | 【实测】返回新 `subscribe_url` 字符串；旧 token 立即失效 |
| 套餐(登录态) | `/user/plan/fetch` | GET | 含购买资格 |
| 下单 | `/user/order/save` | POST | `plan_id`,`period`（枚举【已核验 Plan.php:55-61】：`monthly`/`quarterly`/`half_yearly`/`yearly`/`two_yearly`/`three_yearly`/`onetime`/`reset_traffic`；旧版 `month_price` 等字段服务端自动映射，客户端一律使用新枚举）,`coupon_code?` |
| 支付方式 | `/user/order/getPaymentMethod` | GET | 【实测】未配置支付插件时返回 `[]`。**修正（v0.5）：Xboard 仓库自带 `plugins-core/` 支付插件**——AlipayF2f、Epay、Mgate、Btcpay、CoinPayments、Coinbase、Telegram，随部署挂载 `./plugins` 即可启用；V2Board 核心自带 `app/Payments/` 实现仍可作参照 |
| 收银 | `/user/order/checkout` | POST | `trade_no`,`method`(支付方式ID) → `type`(`0`=二维码内容 / `1`=跳转URL / `-1`=免费单已支付【已核验 V2Board 插件返回与 Xboard 透传】),`data`(二维码内容或 URL) |
| 订单 | `/user/order/check` `detail` `fetch` `cancel` | GET/POST | `trade_no` |
| 优惠券 | `/user/coupon/check` | POST | `coupon_code` |
| 公告/工单/文档 | `/user/notice/fetch` `/user/ticket/*` `/user/knowledge/*` | GET/POST | P1 |
| 邀请 | `/user/invite/*` | GET | P2 |

### 5.3 联调确认项（2026-08-30 M0 实测冻结 ✅）

原待联调项已在 M0 测试面板实测归档（硅谷机 `127.0.0.1:7001`，原始 JSON 存服务器 `/opt/xboard-test/capture/`）：

1. ✅ **注册字段**（源码+实测）：`email`、`password`(≥8)、`email_code`（6 位数字；`email_verify` 开启时必填；缓存键 `EMAIL_VERIFY_CODE_{email}`，TTL 300s，发送限频 60s）、`invite_code`（`invite_force` 开启时必填；当前配置=选填可空）。实测全链路发码→注册成功。
2. ✅ **`subscribe_url` host**：面板 `subscribe_url` 设置项优先（多域名逗号分隔），未设置回落请求 Host。
3. ✅ **响应包络**：`{status,message,data,error}` + 无 `status` 变体（§5.1）。
4. ✅ **订单/支付**：`getPaymentMethod` 未配置时 `[]`；`order/save` 对无对应周期价格的套餐拒绝（"套餐周期参数有误"）；checkout `type` 契约已源码核验。**唯一遗留**：安装支付插件 + 商户凭据后的 checkout 端到端实测（待运营提供支付宝当面付/Epay 等商户参数）。
5. ✅ **HTTP 状态码**：成功 200；订阅 token 错误 403。

**M0 出口标准"API 事实表冻结"：达成**（仅支付收银端到端实测待商户凭据后补）。

---

## 6. 域名自动切换方案（初步设计）

### 6.1 原则

纯客户端**无法凭空得知**新域名——运营侧必须先"广播"，客户端才能"收听"。方案 = 运营侧多源广播 + 客户端多级回退轮询，达成分钟级准实时（启动/故障即触发，最快秒级）。

### 6.2 数据流

```
运营方更换域名
   │  更新引导源(多份): CF Worker / 备用域名 / DNS TXT
   ▼
客户端触发拉取(启动/请求失败/定时)
   │  依次尝试引导源列表
   ▼
解析 domains.json ──► 合并进本地域名池(持久化)
   │
   ▼
健康探测(guest/comm/config) ──通过──► 设为活跃域名
   │                                  ├─► API 请求透明迁移
   │                                  └─► 订阅 Profile URL 换 host + 更新
   └──全池失败──► 救援模式 UI(手输/扫码/公告)
```

### 6.3 引导源 JSON Schema（建议）

```json
{
  "version": 1,
  "updated_at": 1724950000,
  "api_domains": ["https://api.example.com", "https://api2.example.com"],
  "bootstrap_sources": [
    "https://rescue1.example.workers.dev/domains.json",
    "https://backup.example.org/domains.json"
  ],
  "dns_txt_hint": "_entry.example-resolve.net",
  "min_app_version": 1020000,
  "announcement_url": "https://status.example.com",
  "region_catalog": [
    {"code": "HK", "name": "香港", "plan_ids": [1, 2]},
    {"code": "JP", "name": "日本", "plan_ids": [2]}
  ]
}
```

> `region_catalog` 为**可选降级字段**：运营侧已部署地域目录插件时（F-NODE-7 通道①）以插件实时数据为准，仅插件不可用时回退到该静态字段。

### 6.4 客户端实现落点【已核验：衔接点均在现有工程存在】

| 组件 | 落点 | 说明 |
|---|---|---|
| 域名池/活跃域名状态 | 新增 `lib/xboard/domain_manager.dart` + Riverpod provider | 域名池、unhealthy 标记、切换状态机 |
| 统一 API Client | 新增 `lib/xboard/api_client.dart`（基于 dio，可复用 `lib/common/request.dart` 的 Dio 经验但独立实例，避免污染通用下载逻辑） | BaseURL 从 domain_manager 读取；鉴权拦截器；连接层失败分类回调 |
| 引导源拉取 | 新增 `lib/xboard/bootstrap_fetcher.dart` | 多源依序 + DNS TXT 解析（可用 dio 直查 DoH） |
| 健康探测 | 同上 | `guest/comm/config` 快速超时（5s） |
| 订阅联动 | 改造 `lib/models/profile.dart` 的 `ProfileExtension.update()` 调用链与 `lib/controller.dart` 的 `updateProfile`（controller.dart:482 附近） | 受管 Profile 概念；换域后自动更新 |
| 触发时机挂载 | `lib/application.dart` 生命周期定时器（现已有 24h 订阅扫描定时器可参照）；`lib/manager/connectivity_manager.dart` 网络恢复事件 | |
| 凭据安全存储 | 新增依赖 flutter_secure_storage | |

### 6.5 运营侧配合要求（交付运营方）

1. 部署 ≥2 个互不相关的引导源（建议 CF Workers + 一个冷备用域名）+ 可选 DNS TXT。
2. 域名更换 SOP：新域名就绪 → 更新全部引导源 → 客户端在下一触发点自动迁移（分钟级）。
3. 面板侧保持 `guest/comm/config` 可匿名访问（健康探测依赖）。
4. Xboard 核心不含支付插件，需在面板安装并配置支付插件（可参照 V2Board 核心自带实现迁移），并确认插件收银返回形态与 §5.2 `type` 契约一致（影响 F-PAY-2 渲染分支）。
5. 注册开关配置（Q2 已决）：**邮箱验证码必填、邀请码选填**（选填邀请码用于 aff 返利）；面板开启邮箱验证开关，邀请码不设强制，M0 抓包冻结字段名（§5.3-1）。
6. iOS IAP 桥接（Q7 已决配套）：部署票据校验与入账服务（App Store Server API + Server Notifications V2，建议以 Xboard 插件实现），并配置 IAP 商品与"套餐×周期"映射。
7. 试用体验套餐（Q4 已决配套）：面板开启 `try_out_enable` 并指定 `try_out_plan_id`，时长按半小时配置（`try_out_hour=0.5`，字段为 numeric 支持小数【已核验 ConfigSave.php:32-34】）；体验套餐可访问哪些节点由运营在节点权限组中维护。
8. 地域目录端点（F-NODE-7 通道①）：以 Xboard 插件提供 guest 级地域目录接口（聚合节点表地域与套餐映射，仅暴露地域名/套餐关系，不含节点地址），供客户端做权限分层与热更。

---

## 7. 初步实现方向（架构与里程碑）

### 7.1 新增模块结构（建议）

```
lib/xboard/
  api_client.dart        # XboardApiClient：BaseURL 注入 + Bearer 拦截器 + 错误分类
  endpoints.dart         # 端点常量与请求/响应模型(freezed)
  domain_manager.dart    # 域名池、状态机、切换编排
  bootstrap_fetcher.dart # 引导源多源拉取 + DNS TXT
  auth_repository.dart   # 注册/登录/找回/会话
  order_repository.dart  # 套餐/订单/支付
  user_repository.dart   # 用户/订阅/公告/工单
  subscription_binding.dart # 账号↔受管Profile 绑定与换域热切换
  node_packager.dart     # 节点地域聚合/脱敏改名/mihomo自动组包装/状态词数据源
lib/views/store/         # 商店、订单、支付收银页
lib/views/account/       # 登录/注册/找回、我的页
```

### 7.2 与现有工程的融合原则

- 商业链路全部收敛在 `lib/xboard/`，通过 Riverpod provider 与 controller 暴露给 UI；不把面板概念渗入现有 clash/profile 核心层，保证上游可合并性。
- 受管 Profile：在现有 `Profile` 模型上加标记字段（如 `managedByAccount: true`），复用其校验、保存、应用、自动更新全部既有能力，不另造订阅管线。
- 支付 WebView 仅 Android 引入（`webview_flutter` 或 `flutter_inappwebview`），桌面复用 url_launcher + 轮询。

### 7.3 里程碑

| 里程碑 | 内容 | 出口标准 |
|---|---|---|
| M0 联调基线 | 部署 Xboard 实例 + 安装支付插件 + 配置试用体验套餐与注册开关 + 引导源雏形；完成 §5.3 抓包归档 | API 事实表冻结 |
| M1 账号+订阅联动 | F-AUTH(P0) + F-SUB-1/2/3 + F-NODE-1/2/3/5（地域聚合与状态词）+ 我的页骨架 | 真机注册→自动出订阅→按地域选择可连接 |
| M2 支付闭环 | F-PLAN + F-PAY(P0) + **F-NODE-6/7（地域权限分层与目录热更，含运营侧地域目录插件）** | 下单→支付→套餐即时生效全流程真机通过；支付后新地域即时解锁 |
| M3 域名切换加固 | F-DOMAIN 全部 P0 + 救援模式 | 断主域名 60s 内自动恢复（§3.1 验收） |
| M4 桌面端对齐 + P1 批次 | 工单/公告/文档/邀请/余额、F-NODE-4 负载均衡；三桌面端验收 | 全平台回归 |
| M-iOS（并行轨） | iOS 工程立项：NetworkExtension 隧道、签名与开发者账号、商店合规；接 Apple IAP（Q7 已决）——商品映射、服务端票据校验与入账桥接联调；UI/业务层复用 Flutter 代码 | 与 M1–M4 并行推进，独立验收（§9 R9） |
| M5（远期） | 深链快速登录、多语言扩展、匿名开源发布流程执行（R1 处置清单） | 另立方案文档 |

### 7.4 测试要求（摘要）

- domain_manager 状态机、bootstrap JSON 解析、订阅 URL host 替换、auth token 刷新/失效分支为单元测试重点（纯逻辑可测）。
- 域名切换与支付轮询走集成测试（mock server）+ 真机验收。
- 安全项：日志脱敏断言、安全存储落盘检查。

---

## 8. 假设清单（当前生效，评审可推翻）

| # | 假设 | 影响 |
|---|---|---|
| A1 | Android 收银用内嵌 WebView（新增依赖），桌面外链 | 依赖与收银页形态 |
| A2 | 引导源至少一个支持证书固定；DoH 方式解析 TXT | 安全基线 |
| A3 | 平台节奏：Android/桌面主线交付，iOS 并行轨推进（隧道工程独立排期） | 里程碑排序 |
| A4 | 商业版沿用 Flutter 3.44.x 工程与上游构建链（setup.dart/CI） | 构建体系 |
| A5 | 单面板绑定（域名池内的域名都指向同一 Xboard 实例） | 域名切换语义 |

## 9. 风险与开放问题

| # | 类型 | 描述 | 处置建议 |
|---|---|---|---|
| R1 | 法务/**已决策** | GPL-3.0：接受**全开源路线**。当前仓库为**封闭开发仓库**，永不直接发布；未来以全新匿名 GitHub 账号发布开源版本，开发主线与主导权始终保留在自有仓库。开源后被他人复用盈利可接受（视作生态扩散） | 发布节奏（Q8 已决）：**beta 阶段仅内部测试、不对外分发、不开源**（内部测试分发不触发 GPL 义务）；自**正式版**（由项目所有者明确宣布）起，每个对外发布的二进制同步在匿名仓库发布对应版本源码；一旦开始对外分发（含公测）义务即触发且不回退。开源发布前必须：①剥离签名密钥、CI 凭据、内部文档与配置；②重写/压缩 git 历史并匿名化作者信息（commit 邮箱、签名），确保无法关联现有账号；③保留上游（Bettbox/FlClash/mihomo）LICENSE 与版权声明；④发布仓库与开发仓库物理隔离，发布后仅单向同步 |
| R2 | 产品 | ~~手动导入能力去留~~ 已决：代码保留、UI 不引用（F-SUB-6） | 无 |
| R3 | 技术 | 注册条件字段、checkout type 枚举、period 枚举未定（§5.3） | M0 联调抓包冻结，不得凭猜测编码 |
| R4 | 边界 | `getSubscribe` 无套餐即失败；订阅 host 可能与 API host 不同源 | 状态机显式处理；host 替换按服务端 URL 结构做 |
| R5 | 运营 | 引导源本身被封/遗忘更新 → 切换失效 | 多源冗余 + 域名更换 SOP + 公告兜底 + 救援模式 |
| R6 | 合规 | 境内分发/VPN 运营政策、Google Play VPN 专项政策（VpnService 声明、隐私政策、加密合规） | 运营方确认分发渠道与目标市场后补充合规章节 |
| R7 | 工程 | 上游（Bettbox/FlClash）持续演进，商业定制加大合并冲突 | 商业代码隔离在 lib/xboard/；定期 rebase 上游 tag 并回归 |
| R8 | 安全 | token 泄漏 = 账号被盗 | 安全存储 + 日志脱敏 + resetSecurity 兜底 |
| R9 | 合规/重大（iOS） | iOS 同步立项带来：①App 内购买数字订阅按 Apple 政策须走 IAP，面板支付插件（支付宝/USDT 等）不能直接用于 iOS 内购；②当前仓库无 ios/ 目录，NetworkExtension 隧道与签名体系从零建设；③VPN 类 App 审核严格、周期长、有被拒风险 | **已决策接 IAP（Q7）**：IAP 商品映射套餐周期，服务端完成票据校验与面板入账（F-PAY-7、§6.5-6）；iOS 定价须计入 Apple 分成（标准 30%/中小开发者计划 15%）；Android 走自有渠道分发不受此约束，若上架 Google Play 则同样须接 Play Billing；隧道方案优先调研 mihomo/sing-box 在 iOS 的成熟集成先例；UI/业务层最大化复用 Flutter 代码摊薄成本 |

**开放问题清单**——Q1–Q8 已全部决策：
- Q1 手动导入：代码保留、UI 隐藏（F-SUB-6）。
- Q2 注册条件（已决）：**邮箱验证码必填、邀请码选填**（aff 用）；字段名留待 M0 抓包冻结（§5.3-1）。
- Q3 支付 `type` 契约：已从源码核验（§5.2）。
- Q4 无套餐态（已决）：由 **Xboard 试用套餐承接**——新用户默认开通半小时体验套餐（`try_out` 原生支持已核验，配置见 §6.5-7）；客户端保留兜底态（F-SUB-1）；短周期套餐按分钟级倒计时提醒（F-SUB-3）。
- Q5 品牌/包名：网穿云 / `com.cloudbreach.app`。
- Q6 iOS 立项：同步并行（M-iOS 轨）。
- Q7 iOS 支付：接 Apple IAP（F-PAY-7、§6.5-6）。
- Q8 开源节奏（已决）：**beta 仅内测不开源；正式版起每版同步源码**（R1 发布节奏）。

当前无阻塞开放问题。遗留的字段级确认项统一收敛在 §5.3，于 M0 联调时归档。

---

## 10. 附录

**术语**：面板=Xboard 实例；受管 Profile=由账号自动生成、用户不可编辑的订阅条目；引导源=运营方维护、下发布效域名的广播端点；连接层失败=DNS/连接/TLS 层错误（区别于 4xx/5xx 业务错误）。

**事实来源**：本 PRD 中【已核验】项分别来自——本仓库源码（`lib/models/profile.dart`、`lib/common/request.dart`、`lib/controller.dart`、`lib/application.dart`、`pubspec.yaml` 等）与 Xboard 上游仓库（`cedar2025/Xboard`：`app/Http/Routes/V1/*`、`app/Http/Controllers/V1/*`、`app/Http/Middleware/Client.php`、`app/Services/AuthService.php`、`app/Http/Requests/Passport/*`、`app/Models/Plan.php`，master 分支，2026-08-29 读取）。

**本地参考克隆**：支付契约与周期枚举核验自两上游项目的本地只读克隆（浅克隆，位于本仓库平行目录，不纳入本仓库版本管理、不修改）：`../Xboard`（cedar2025/Xboard）、`../V2Board`（v2board/v2board，核心自带 `app/Payments/`，`type` 注释与返回结构为 §5.2 契约的直接依据）。

**M0 联调环境**（2026-08-30 上线）：硅谷轻量 #3.2 `/opt/xboard-test/`——Xboard latest 单容器（ghcr.io/cedar2025/xboard，SQLite + 内置 Redis，绑定 `127.0.0.1:7001`，mem_limit 900m，随附 `plugins-core/` 全部支付插件于 `./plugins/`），前置 Caddy edge（主机 `:8443`，自签 SAN 证书反代）。已配置：邮箱验证码必填、邀请码选填、半小时试用套餐（`try_out_hour=0.5`，plan_id=1，`sell=false` 不上架商店）。实测闭环：发验证码 → 注册（自动开通试用套餐）→ 登录 → getSubscribe（subscribe_url 下发）→ 订阅拉取（mihomo YAML 9.7KB + Subscription-Userinfo 头）。管理员凭据存服务器 `/opt/xboard-test/ADMIN_CREDENTIALS.txt`（600）。
**M0 暴露状态**（2026-08-30 全部生效）：域名 `https://cloud.microsoftnexushub.top:8443`（CF 橙云 → 主机 8443 ufw 放行 → Caddy edge → 7001）全链路可用；排障记录：阻塞根因 = 腾讯控制台防火墙 + **主机 ufw 未放行 8443**（ufw active、INPUT 默认 DROP），两层都已放行。邮件：Gmail SMTP + App Password 实测发信成功，经域名发注册验证码到真实收件箱成功；`subscribe_url` 经域名访问自动生成为 `https://` + 正确域名（edge 透传正确）。**遗留待办**：管理员改密（首次登录）、支付插件商户配置与 checkout 实测。

**寄生中转插件 CloudBridgeRelay**（2026-09-01 上线，测试面板 `/opt/xboard-test/plugins/CloudBridgeRelay/`，已启用；源码以本地 `../Xboard/plugins/CloudBridgeRelay/` 为准，改后 scp 到面板并 `docker compose restart xboard`）：一键导入上游机场订阅为面板寄生节点（vmess+ws，**无损保留上游原始节点名**——地域聚合与国旗展示完全由客户端 `kRegionRules` 规则引擎承担，服务端不再改名归并，杜绝窄映射表把長尾地区塌成「优选」；同名冲突追加序号；去重键 `server|port|path|uuid`；上游 uuid/cipher 经 `tags` 列载体 + ClashMeta.buildVmess / ServerService vmess 双补丁覆盖下发）。管理：`php artisan cloudbridge:relay sync|import|status|hide|show`（`sync --url=` 一键填入订阅链接；`import --file=` 读取本地 Clash YAML 导入——用于 GeoDNS 给服务器出口下发不可用变体时把国内出口拉到的 IP 版变体作为事实源）；定时自动同步（间隔可配，默认 360 分钟节流）；每次同步记录上游 `subscription-userinfo` 流量水位，耗尽自动下架寄生节点（恢复自动上架）。**同步可用性护栏**（2026-09-02 实测）：上游按请求出口地域发不同变体——硅谷出口拉到 55 名 2 出口的 `*.qawer.cloud` 域名坍缩变体（服务器侧 DNS 可解析），直接同步会覆盖可用 IP 节点；`variantsUsable()` 双判据拦截（域名至少一个可解析 + 去重后唯一连接参数 ≥ min(3,总数) 且 ≥25%，拦截改名伪造坍缩变体），拦截时保留现有节点并报错。实测：55 节点 = 24 地区 + 懒人兜底（同服务器多马甲规模 2 出口）；上游账号 500GB 已用 18.5GB（2026-10-01 到期）。**F-DOMAIN 域名自愈（M3 客户端侧，2026-09-02 推进）**：按 §3.1 无感切换设计落地客户端全链路——① `XboardDomainManager` 域名池（内置 + 引导源下发合并去重；活跃域名被引导源退役则自动切新列表首项；救援态判定）；② `XboardBootstrapClient` 引导源多源顺序拉取（§6.3 schema 解析，非法源自动回退；开发期默认源=面板同域 `https://cloud.microsoftnexushub.top:8443/bootstrap.json`，已由 Caddy edge 静态路由提供，运营正式源见 §6.5-1）；③ `XboardDomainScheduler` 调度器：冷启动加载持久化池→异步引导源+健康探测（`guest/comm/config`），6h 定时刷新；连接层失败（Dio 分类）自动轮换后同步订阅；④ 订阅 URL host 热替换（`binding.rewriteHost`，仅替换 scheme/host/port 保留 path/query，服务端 `subscribe_url` 仍为权威）；⑤ 救援模式 UI：仅全池失败时首页顶部横幅（一键重试 + 手动输入新域名弹窗，输入写回池并自动验证），平时零界面。验收对齐 §3.1：断主域名 ≤60s 自动恢复已由失败轮换链路覆盖；冷启动用持久化新域名已闭环（安全存储 `xboard_domain_pool`）。**当前单域名（无第二入口），轮换无实际候选**——需运营侧提供备用域名并写入引导源 `api_domains` 后方可实测"无感切换"终态；CF Workers 等独立备份源同属运营侧（§6.5-1）。

**寄生合规提醒**：转售上游节点可能违反上游 ToS，商用需评估。

**引导源管理面板（2026-09-02 集成进寄生管理页）**：`panel.html`（`/plugins/CloudBridgeRelay/panel.html`）新增「引导源域名池」卡片——展示引导源地址与当前域名列表，支持添加（逗号/换行批量）、删除、**双向测试**（「本地」= 浏览器 no-cors fetch 判国内出海可达性，含证书校验，自签开发证书报不可达属预期；「服务器」= 面板机 `POST /bootstrap/test` 探测 DNS + `guest/comm/config` 状态码/耗时）；保存即调 `POST api/v1/plugin/cloudbridge-relay/bootstrap`（body `{api_domains:[...]}`，非法条目剔除、去重、保留其余 schema 字段），落盘到宿主 `/opt/xboard-test/bootstrap/bootstrap.json` 后由 Caddy edge `/bootstrap.json` 即时对外（dev 默认源；独立冗余源属运营侧 §6.5-1；**池语义：任一域名存活即可被客户端轮换命中，全池失败才进救援模式**）。**运维红线**：xboard 容器挂载为 `./bootstrap:/www/storage/bootstrap:rw`——`/www/bootstrap` 是 Laravel 框架目录（`bootstrap/app.php`），**切勿挂载覆盖**，否则容器全线瘫痪（2026-09-02 实测踩坑已修正）；edge 侧 `./bootstrap:/srv/bootstrap:ro` 只读。**后台入口**：admin/theme 双模板（`/www/resources/views/admin.blade.php` + `/www/theme/Xboard/dashboard.blade.php`）经 compose bind mount 注入 `cbrelay-entry.user.js`（后台「服务器管理 /server」页右下浮动按钮直达管理面板），Xboard 升级镜像不覆盖挂载文件；插件系统自身无导航扩展点（前端闭源），此注入是入口的唯一可靠通道。**凭据文件事故（需用户处理）**：`/opt/xboard-test/ADMIN_CREDENTIALS.txt`（600，8-31 创建）内容已被某次容器启动日志覆盖（实测 1619B 全为 compose 输出），管理员密码不受影响（此前已由用户自行改密）；该文件已无凭据价值，建议用户确认后删除或重建。

**多上游订阅管理器（2026-09-02）**：插件配置 `upstreams` 数组（{url,label,enabled,last_sync_at}，旧 `upstream_url` 自动迁移）；**核心场景 = 同一上游多个账号订阅链接**（不同 uuid 密钥 → 扩展单上游并发量与流量），同时支持不同上游混用。语义：**源内去重**（同订阅内 同server|port|path|uuid 折叠），**跨源并存**（不同源同参节点也上架，`code = md5(dedupeKey|sourceHash)` 规避 `v2_server(type,code)` 唯一约束）；节点 tags 带 `relay-src:<hash>` 归属标记，同步/删除/耗尽下架均按源隔离（某账号流量耗尽只下架该源节点）；每源独立节流与 `usage_snapshots` 流量水位（**护栏拦截时也保存流量快照**——订阅头与节点可用性解耦，耗尽账号的用量/到期仍可见），`status` 汇总总节点与各源用量并回传 `sync_interval_minutes`。节点名仍无损保留上游原名，客户端 `kRegionRules` 统一聚合。**节点获取双通道（2026-09-02）+ 出口实验结论**：`POST /upstreams/import {url, content}` 上传 Clash YAML 文本导入节点归属该源（**文件扩展名不限**——上游导出的配置未必带标准 yaml 后缀，按文本读取后服务端解析；与订阅拉取并存：URL 承担流量水位与定时探测，文件承担节点事实源，同一 relay-src 标记、删源一并清理；前端源卡「上传配置」按钮 FileReader 直传）。实验证实 SV 无法自动拉取可用变体：① 上游 GeoDNS 对 SV 出口下发 `*.qawer.cloud` 域名坍缩变体；② 域名解析到 `111.47.247.246:80` 但**该中转只对国内网络开放，SV 直连 i/o timeout**（sub-mihomo 借 192539 节点做出口代理的 health-check 全挂同理）；③ 因此"服务器自动拉可用节点"不可行，上传配置是国内视角配置落地的唯一通道。**管理面板（2026-09-02 重构为三页签）**：页1「状态监控」统计卡（源数/节点合计/流量合计/最近到期）+ 各源概况；页2「源管理」**一源一卡平铺**（用量条/剩余/到期/节点数/上次同步/单源同步/上传配置/上架下架/删除，源级错误消息如实透传）+ 自动更新周期设置（5-10080 分钟，`GET/POST /settings`）+ 全部更新 + 批量添加；页3「引导源域名池」（双向测试）。命令：`cloudbridge:relay upstreams|sync(--url/--label)|import(--file)`。存量 55 节点已一次性迁移打上 `relay-src:local` 归属。**实测记录（2026-09-02）**：同上游第二账号 `…/clash/192539/…` 订阅头显示 700GB 已用 699.86GB（剩 0.26GB，9-13 到期）——上游对耗尽账号下发不可用变体，护栏拦截属预期行为；该源卡片仍展示用量与原因。**耗尽暂存语义（已闭环验证）**：流量耗尽的源节点**下架隐藏而非删除**（暂存，`show=false` 不影响订阅输出），运营在上游充值加购后同一订阅链接自动恢复正常 → 周期同步（每 10 分钟调度 + 本源自节流）重建节点并自动上架；已用/总量/到期三判定（剩余≤0 或已过期即下架）经容器内实测 EXHAUSTED_HIDDEN=1 / REFILLED_SHOWN=1 / EXPIRED_HIDDEN=1。前端包络按 Xboard `{"status":"success"|"fail",...}` 字符串形态解析（非数字码）。**故障兜底与按源可见性（2026-09-02）**：`syncOne` 全路径 try/catch——拉取/非 YAML 解析/写入任何异常转为源级错误消息（如 `同步异常: Unable to parse at line 1 (near "<!doctype html…")`），管理端点不再 500（此前用户实测"✗ 遇到了些问题"即 Yaml::parse 抛异常所致）；每源独立「上架/下架」按钮（`POST /upstreams/visibility {url,show}`，下架=隐藏暂存，`status.sources[].visible` 供 UI 判定），全局上架/下架已从引导源页移除、移入单源卡片；CLI 全源同步逐源打印失败原因而非笼统"同步失败"。**管理页加载健壮性（2026-09-02）**：`/settings` 500 根因为 Octane worker 加载旧类定义（方法不存在），重启后恢复（新端点部署必须 `docker compose restart xboard`，仅文件覆盖不生效——插件类被 worker 常驻缓存）；前端 `refreshAll` 返回 `Promise.allSettled`（此前 void 导致启动 `.catch` TypeError）、`refreshStatus` 统计渲染与 `/settings` 独立降级（settings 失败不再清零统计卡），统计卡与信息卡 padding/圆角/字号统一。**部署纪律（2026-09-02 两次踩雷后固化）**：① Controller 的 `fail()` 必须传字符串——`fail([...])` 数组会触发 Xboard `ApiResponse` 的 `Undefined array key` Level-2 错误被 HandleExceptions 转为 500（"遇到了些问题"）；② 多命令部署 heredoc 多次在 lint 后中断导致 restart 静默未执行——**restart 后必须用 `docker inspect StartedAt` 或端点探测确认生效**，不能只信输出。

**SSR 上游不兼容结论（2026-09-04）**：Hitun 机场（rss-node）clash 订阅 63 节点全为 SSR（ShadowsocksR）；实测 `target=ss/trojan` 空响应、`target=vmess/vless/hysteria2` 返回 400——该机场无 mihomo 可用格式，与 Bettbox 架构不兼容（SSR 是 mihomo 内核能力边界，非面板缺陷）。面板上传导入已加**类型分布提示**：SSR 等不被支持类型导入时明确提示"N 个节点均为 SSR（ShadowsocksR），客户端 mihomo 内核不支持，无法上架"，而非笼统 0 节点。

**多协议接入（2026-09-04，kuaiyu 实测打通）**：上游常按 UA 返回不同格式——浏览器 UA 得 base64 的 v2rayN 链接列表（`anytls://` `hysteria2://` `ss://`），clash UA 得 Clash YAML。服务端新增 `parseNodeConfig` 统一解析器（clash YAML / base64 包裹的 YAML / base64 的 v2rayN 链接列表三态，URL 解析含 anytls/hysteria2/ss(SIP002+旧式)/vmess/vless/trojan；localhost/127.0.0.1 占位提示节点自动过滤），`syncOneRaw` 响应体与 `importUpstream` 上传内容共用。**节点类型扩展**：rebuildNodes 支持 anytls/hysteria(v2)/shadowsocks/vmess 入库（`normalizeType`：hysteria2→hysteria v2、ss→shadowsocks；SSR 计入 skipped 提示）；**真实链接密码走 tags `relay-password:` 载体**（protocol_settings 受 Xboard `PROTOCOL_CONFIGURATIONS` schema 白名单过滤，密码字段会被丢弃）；ClashMeta 补丁对 buildAnyTLS/buildHysteria/buildShadowsocks 统一做 tags 密码 override + hy2 up/down 空值跳过；**所有 relay 增删查改移除 `type=vmess` 限制**（按 relay-src 标记跨协议操作，此前仅 vmess 导致多协议节点无法删除/重建 → UNIQUE 冲突，已修）。实测：kuaiyu 260GB 账号 20 节点上架（11 anytls + 8 hysteria + 1 ss，含 CN2 三网优化/家宽 等地区命名，客户端 kRegionRules 可聚合）；buildAnyTLS 输出验证 password=sni 正确覆盖用户 uuid。
