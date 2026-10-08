# 付呗候选支付插件

本目录交付适配 Xboard `PaymentInterface` 的候选源码。插件安装默认禁用，插件全局与支付方式配置的 `enabled` 均默认 false。Bettbox 桌面和 Android 复用 checkout `type=0` 二维码及订单轮询；iOS 使用 Apple IAP。

## 配置契约

管理员需确认商户聚合码配置完成，并在支付方式后台配置：

- `identity_mode`：`merchant` 或 `vendor`；对应 `app_id` 或 `vendor_sn` 二选一。
- `merchant_id`、`store_id`：均必填用于回调身份核对。服务商级下单发送商户编号，商户级下单不发送。
- `gateway`：官方确认的 HTTPS 网关；`gateway_hosts` 为网关精确主机白名单。
- `payment_hosts`、`notify_hosts`：官方支付二维码主机和本方回调主机精确白名单，逗号分隔，不支持通配符、IP、非443端口、用户信息或片段。
- `secret_ref`：服务器密钥引用名称。服务器需安全提供 `config('payments.fubei.secrets.<引用名称>')`，后台仅存引用，不存密钥原文。该服务器配置适配尚待部署方完成，本插件不读取环境文件、不回显或记录秘密。
- `expired_time`：二维码有效秒数，1至1800，默认600。
- `enabled`：候选默认 false；Xboard 支付方式自身的 `enable` 也必须有效。

聚合码前置包括备案阿里域名解析至付呗、认证服务号与授权域名、支付宝应用与回调配置、门店微信配置。具体开通情况未知，不能以已获得开放平台标识代替开通证据。主机白名单属于管理员信任配置；基础设施仍需限制 DNS 与出站访问，避免被允许域名错误解析至内部服务。

密钥轮换必须使用新的 `secret_ref`，不得覆盖原引用指向的密钥值；保留所有未完成尝试对应的旧引用以及回调路由 UUID、支付方式归属与启用状态，直到平台关单或人工核对完成。回调使用尝试快照而非当前支付配置，改变 app_id、merchant_id、store_id 或当前引用不会把旧通知错误验签为新身份。未完成尝试禁止通过轮换配置再次下单；候选不自动查单或换号。

## 上线阻断与幂等边界

插件从 Symfony 原始请求正文解析 POST 表单，不使用已被 TrimStrings 或 ConvertEmptyStringsToNull 变换的 input；限制正文为1 MiB、字段数32，拒绝重复字段、数组字段和异常编码。JSON 顶层字段重复也拒绝；金额从原始 data 的 total_amount token 提取，仅接受直接十进制整数或最多两位小数，不接受指数、长小数和金额字符串转义，禁止 float 金额参与校验。Web 入口仍需配置请求正文大小限制，避免框架处理超大请求。

插件通过账务 Atomic 服务创建不可变支付尝试，平台使用32位 external_no，Xboard 原36位 trade_no 保持不变。回调只用未认证的有界外部号定位尝试，再使用快照的安全 secret_ref、身份、商户与门店核对原始签名和归属，由 SQLite 事务核对快照应收金额、商户、门店、平台流水及订单状态；只有事务到账后返回原订单号交给通用开通流程。未安装账务服务、未执行迁移或数据库目标未经适配时失败关闭，不回退到无快照付款。

**插件尚不具备生产上线条件。** SQLite 计费候选位于 `server/patches/billing`。独立 SQLite 多进程验收和真实 Laravel 隔离集成均已通过；Laravel 验收经过真实 HTTP Kernel、Eloquent、订单服务、同步队列、返佣命令和持久 outbox，认证、插件发现和支付网关传输使用显式夹具。生产数据库迁移、真实插件安装发现、商户配置和人工付款尚未验收，插件保持默认禁用。

网络结果未知后，候选复用同一支付尝试与外部号，但重复 checkout 仍会调用二维码创建接口。相同外部号不构成已验证的官方网关幂等保证；管理员需只读核对平台订单。自动查单、关单、二维码结果持久化与完整人工核对工作流尚未实现。已有未完成尝试不允许切换支付配置或应收金额，需人工核对或安全关闭平台订单后处理。取消后付款或重复流水冲突不能自动开通，保留人工核对证据。到账事务同时持久化 payment.notify.success outbox；开通失败时事件保留，开通完成后由订单任务及每分钟 check:order 恢复交付。钩子保持 Order 参数形状，通过非持久 relation `$order->billing_event->id` 提供稳定事件ID。消费者必须按该ID幂等；进程崩溃、租约过期和部分钩子成功会重复交付，只有至少一次交付语义，不能承诺跨系统 exactly-once。隔离框架已验证按事件 ID 幂等的测试消费者；线上全部消费者的适配仍待核对。

## 验证

纯测试入口，不依赖 Laravel、不发网络请求、不读真实配置：

```sh
php server/tests/fubei/run.php
```

当前候选的 117 项纯契约测试已在 NoSLA 禁网、只读、64 MiB 容器中通过，未挂载业务数据库或凭据。SQLite 独立连接并发测试已通过，覆盖到账、取消、开通、返佣和 outbox；真实 Laravel 串行隔离测试已覆盖 checkout、重复回调、套餐开通、流量重置、返佣与补偿。

Xboard 实际安装发现/启用生命周期、完整框架并发、生产消费者幂等、官方下单响应和人工小额付款仍待验收。公开证据见 `docs/validation/2026-10-07-three-platform/payment-readiness-validation.json`。测试身份均为公开虚构 fixture，只用于规则测试。

## 官方规则来源

- [开发者必读](https://www.yuque.com/51fubei/openapi/qao4q1)：HTTPS JSON 请求、公共参数、ASCII 排序与 MD5 大写签名；网关由商务或技术提供。
- [聚合码支付](https://www.yuque.com/51fubei/openapi/payment_qrcodepay)：`fbpay.fixed.qrcode.create`、元金额、门店、二维码有效期与 qrcode_url。
- [支付回调](https://www.yuque.com/51fubei/openapi/callback_ordercallback)：POST 表单、原始 data 签名、order_sn、uid、total_amount、SUCCESS 与最多26次通知。

规则核对日期：2026-10-07。请求响应 data 按文档 String 处理，不混用旧版 GitBook 字段。官方商户配置和生产行为需部署前核验。
