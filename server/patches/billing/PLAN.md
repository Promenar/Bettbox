# SQLite 计费事务候选与迁移计划

生产未激活。交付包含迁移、数据库事务核心、通用 CAS/开通与返佣候选，以及付呗快照的插件接线。所有代码、迁移和集成行为均须验收通过后才能考虑启用收款。

## 已核对的契约

来源由 manifest 明确区分：OrderService、OrderHandleJob、User/OrderController 使用 NOSLA 容器 /www 三份只读线上源码，其 SHA256 经工具核对，进入上下文前完成字面凭据扫描；其余9个来源为主控确认与线上哈希一致的本地只读 Xboard PHP 8.2 / Laravel 12 源码与迁移。订单 trade_no 唯一、最长36；callback_no 可空无唯一约束。佣金日志没有层级和唯一键。SQLite 是目标，lockForUpdate 不构成行锁证据。

仅付呗创建不可变支付尝试和32位外部号，原订单号保持不变；其它插件保持原通知协议。免费和管理员付款分别为 free/manual 来源，不强制平台流水唯一。取消后已收到的旧通道付款进入人工核对，禁止凭未知身份开通。新佣金日志唯一键为(order_id,level)，旧行两个字段 NULL，不回算已结算佣金。循环邀请拒绝该订单返佣并记录人工核对事件。

## 备份与迁移

1. 隔离副本先校验来源哈希、PHP 语法、SQLite 并发验收及 Laravel 集成。停止付款入口、任务调度、队列和写入者，确认所有进程退出。
2. 对实际 SQLite 文件使用 SQLite backup API 生成完整一致备份，不能只复制 WAL 模式主文件。记录备份 SHA256、PRAGMA integrity_check、源 SHA、schema 与未完成订单数量。秘密与完整付款资料不进入报告。
3. 执行新增 Laravel migration：mutex 行、immutable payment_attempt、人工核对记录、事务 outbox、佣金 nullable order_id/level 与唯一索引。migration 不回填、不改历史余额、不猜历史平台流水。检查现有列/表重名时停止。
4. 部署核对过哈希的候选文件，继续保持付呗关闭；验证旧插件、免费、手动付款、取消、队列补偿、佣金周期。之后才评审付呗接线及人工付款验收。

## 回滚

新增写入前可恢复代码并迁移 down。出现任何新增支付尝试、佣金幂等日志、outbox 事件或人工核对记录后，down 必须拒绝，禁止删除财务证据。生产写入后回滚保持新表与唯一索引，先停止所有写入，保留新证据，再恢复经兼容评审的代码；不得把旧代码直接恢复为并发不安全的付款路径。完整备份恢复会丢弃备份后的交易，必须先人工对账并另获授权。

## SQLite 事务实现

每个顶层事务第一条数据库操作为更新单行 mutex，从而在任何业务读取前获得 SQLite 写保留锁，避免 deferred transaction 的读锁升级竞态。所有读取、CAS、余额与日志写入处于同一个连接事务。数据库 busy 由现有框架重试策略处理；失败返回可重试状态，不吞失败为 success。不切 WAL、修改持久 PRAGMA 或假设 MySQL 锁有效。

订单 pending→processing/cancelled 使用条件更新；开通核心位于同一外层事务；check:order 已有每分钟补偿 pending/processing，不新建重复调度。到账同一事务持久化 payment.notify.success outbox，开通完成后交付，首次开通失败后事件不会丢失。每分钟 check:order 恢复未交付事件；原子租约限制并发领取，崩溃租约到期后恢复。消费者失败从30秒指数退避至最多1小时，领取按最早可交付时间、创建时间和稳定事件ID排序；失败事件重新排到可交付队列后部，不以最老100条永久占据批次。交付在事务外，消费者需按 `$order->billing_event->id` 去重；异常、崩溃或多监听器部分成功允许重复，属于至少一次语义，不能获得跨系统 exactly-once 保证。

## 未完成的集成门禁

付呗插件在下单前创建快照，把32位 external_no 传给平台；回调映射原订单并在 settleAttempt 中事务内核对 signed amount/uid/store/provider scope。checkout 支付配置保存采用相同 SQLite 写事务，已有未完成尝试禁止变更支付方式或应收金额。PaymentService 原接口保持兼容，订单原36位号传入插件后由插件映射，旧插件不改外部编号。候选目录 plugins/Fubei 与 billing overlay 包含同一版插件。

真实 Laravel checkout/回调/开通/队列/钩子、生产 SQLite schema 和人工小额支付均未运行验收。独立进程测试仅证明候选核心及使用真实 SQLite 的插件适配接口，不证明完整框架环境。未实现平台自动查单/关单与人工核对后台，钩子 outbox 已提供但实际消费者的事件ID幂等尚待验收；异常需只读人工对账，生产保持禁用。

新佣金金额沿用现有计算，但拒绝非整数分结果并进入人工核对；向下取整等新舍入政策需另行确认，不猜测。真实服务器 schema 必须在部署前只读核验，源码迁移不是生产数据库证据。

## 密钥与源码安全边界

支付尝试持久化安全 secret_ref 而非秘密原文，回调使用该尝试的 identity_mode/identity_key/merchant_id/store_id/secret_ref。轮换需新引用并保留旧引用原值及回调路由；禁止在未完成尝试期间删除旧密钥引用。已有未完成尝试遇到当前配置变化会拒绝新下单，历史回调可按快照到账。

apply.py 在准备阶段冻结所有已校验 overlay bytes 和原始备份 bytes；应用不重新读取候选源。文件提交点先登记已知 inode 与内容，之后 fsync/stat 或清理失败也纳入当前文件回滚。来源文件的 inode、模式、内容及新增目标不存在性在写入前复核，漂移拒绝。逐级目录句柄使用 O_NOFOLLOW，每次写入和回滚重新核对父路径，拒绝链接替换；新目标排他创建。安全回滚遇到路径漂移会停止并保留备份，要求人工核对，不跟随未知路径覆盖。应用必须排除其它源码写入者；该流程不声称在有权限恶意并发改写普通目标文件的对抗环境中提供原子文件级 CAS。

## 真实框架验收计划（未执行）

线上创建流程的用户重读、未完成订单复核、余额抵扣后 setInvite 计算次序完整保留，创建及开通直接入口使用 SQLite mutex 先写后读；checkout 保留负数拒绝，免费入口仅接受当前数据库金额等于0。开通保留 processing 状态复核、套餐缺失拒绝、订单模型刷新及 TYPE_NEW_PURCHASE 事件类型。CloudBridgeRelay 源码与通知协议没有改动。

隔离 Laravel 完整环境需使用真实 Eloquent、迁移、队列和 HookManager 建立以下 fixture，当前纯 PDO 入口不假称覆盖：

1. 开始金额1000分、余额300分、邀请比例10%，创建后余额0、balance_amount=300、total_amount=700、commission_balance=70；全余额抵扣后应付0，佣金基数按线上次序为0。对同一用户并发创建必须只有一个未完成订单，并验证余额和优惠券副作用不重复。
2. checkout 对负数订单返回拒绝，零金额仅可信 free 来源到账；初读后负数变更也不得通过 Atomic::paid 免费开通。
3. processing 订单缺失套餐时开通事务回滚，保持 processing/outbox 待处理；恢复套餐后真实套餐与流量更新只发生一次，成功事件可补偿交付。
4. CloudBridgeRelay、Epay 和其它已安装旧插件真实 notify 协议、免费入口、管理员付款、取消后迟到通知、重试开通与消费者事件ID幂等回归。

纯 PDO 用例新增负数免费拒绝与101个事件的公平交付：前100永久失败，后续成功事件可在下一批交付；即使前100已经到期重试，新事件也先于退避事件领取。源码应用测试在 replace/link 提交后注入 fsync/stat 故障，验证当前文件亦回滚。以上测试代码尚待主控在隔离执行器运行，完整框架 fixture 尚未实现。

## 负金额人工核对

到账的 legacy/manual/free 来源在同一写事务内重新核对 total_amount 和 handling_amount，不允许任何负值进入 processing。历史 processing 开通在状态重读后、套餐/钩子/余额/流量处理前应用相同防护。负值保持原金额、回调号、付款时间与状态，不猜修正；negative_order_amount 核对证据随正常事务返回提交，重复重试仅保留一条记录，不以异常回滚该证据。付呗下单也拒绝负值；已验签的付呗流水遇到原订单变负，保存流水并把尝试置为人工核对，不开通。

新增真实 PDO fixture 覆盖负总额与负手续费的 pending/processing、三个受信来源拒绝、开通动作不调用、用户余额/开通次数/佣金日志不变、历史回调与付款时间不变、核对记录持久化和幂等，以及付呗快照后金额变负的流水保留。OrderService.open 的完整 Eloquent/套餐/HookManager 路径仍须真实 Laravel 验收，当前 fixture 不代替它。

源码应用要求明确的物理规范路径；路径任何组件为符号链接均拒绝。macOS 临时测试根的 /var 别名仅在测试 fixture 中 resolve 为 /private/var；业务应用脚本不自动解析链接或放宽 O_NOFOLLOW。

## checkout 负手续费边界

checkout 在同一 SQLite 写事务里计算 handling_amount 并赋值后调用 guardAmountsInside；失败返回 null 而非抛异常，使 negative_order_amount 核对记录提交。外层发现空结果直接返回失败，不调用 PaymentService.pay，不保存负手续费和支付方式变更。已有平台尝试的冲突检查与原手续费计算公式保持。

checkout_worker.php 执行实际候选 OrderController.checkout，模型/请求/支付网关仅为接口外壳，所有持久化与并发使用独立真实 SQLite PDO。六个进程验证旧 Epay 类型、total_amount=1000、fixed_fee=-100、合计900仍全部拒绝，网关 pay 调用为0、核对记录1、订单原字段不变；正手续费100的对照验证调用一次且金额1100。此适配用例不等于完整 Laravel 插件生命周期已覆盖，真实框架仍须用 Epay/CloudBridgeRelay 安全网关 spy 核验同一路径。测试未在施工侧运行。
