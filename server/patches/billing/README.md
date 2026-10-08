# SQLite 计费候选补丁

生产未激活。迁移、备份、回滚及集成门禁见 [PLAN.md](PLAN.md)。overlay 是针对 manifest 指定来源的候选终态文件，其中三份订单源码使用已扫描的真实线上只读基线，保留旧支付插件通知协议；付呗插件和 checkout 已接入快照核心，但完整框架与真实支付尚未验收，不允许启用付呗。

默认仅核对源码与候选哈希，不写目标、不读取数据库、不运行迁移：

```sh
python3 server/patches/billing/apply.py --target /path/to/isolated-xboard
```

隔离验证环境明确接受写入后才用 `--apply`。脚本保留原源码备份，拒绝来源漂移、新增目标冲突或符号链接；不会启动服务、迁移数据库或改变插件启用状态。应用期间必须排除其它源码写入者。目标须为明确的物理规范路径，任意路径组件的符号链接都会拒绝；macOS 临时目录测试 fixture 使用实际 /private/var 根，不放宽业务边界。

独立进程 SQLite 测试使用真实 PDO 和文件数据库，运行候选 Atomic.php 与相同迁移 SQL，不用内存数据库或模拟数据库：

```sh
python3 server/tests/billing/run.py --php /path/to/isolated/php
```

PHP 需8.2及 pdo_sqlite，不自动安装。测试临时目录内创建并删除一次性测试数据库，不碰实际部署数据。测试覆盖多进程到账/取消 CAS、退款一次、开通一次、返佣日志及余额一次、事务失败回滚、快照复用与不可变、流水跨订单冲突、自邀及购买者参与三层循环的事务回滚和人工核对、配置轮换后的历史快照验签、首次开通故障与 outbox 恢复、消费后崩溃及事件ID幂等、实际 checkout 控制器适配路径的负手续费拒绝与零网关调用、各受信来源负数拒绝、历史负数 processing 无开通副作用且核对证据持久化、付呗负金额流水保留与100个永久失败事件后的公平交付，以及36位内部订单与32位平台尝试号的插件下单/原始回调多进程映射。测试 schema 只保留实际源迁移的相关字段及开通计数器；Laravel 模型/队列/钩子及实际套餐逻辑仍需真实框架集成测试。

补丁文件安全边界独立验收（候选 bytes 冻结、目标存在性漂移、符号链接写入与回滚拒绝、replace/link 提交后 fsync/stat 故障的当前文件回滚）：

```sh
python3 server/tests/billing/test_apply.py
```

隔离 PDO 并发、真实 Laravel Kernel/Eloquent 与迁移检查已执行，覆盖边界与当前源码摘要见 `docs/validation/2026-10-07-three-platform/payment-readiness-validation.json`。生产数据库未迁移，付呗未启用。

`billing:migrate` 默认仅输出计划；`--execute` 在同一 SQLite 顶层事务内执行固定候选文件和 Migrator 成功记录写入，`--execute --rollback` 仅接受最后批次单独属于候选且无新增账务证据。真实 ConsoleKernel 隔离调用、仓库 INSERT/DELETE 故障注入和完整快照核对通过；失败返回固定非零回执，不输出底层异常。重复执行遵循 Migrator 记录，不承担已记录但损坏 schema 的修复。生产命令自动发现、真实 Artisan 启动、schema 核对、停写/备份、强杀/掉电及并发部署仍待验收。

候选文件经安全应用后，隔离目录中的命令为 `php artisan billing:migrate`（计划）、`php artisan billing:migrate --execute`（执行）与 `php artisan billing:migrate --execute --rollback`（受限回滚）。生产执行需先完成 PLAN 中的部署门禁；不使用普通全目录 migrate 来替代共同事务命令。


真实 Laravel 双进程创建、取消、通知、取消/到账竞争和返佣已通过隔离验收，证据见 `docs/validation/2026-10-07-three-platform/laravel-business-concurrency-validation.json`。仅验证单轮双进程与同步任务；其它优惠券限制、生产管理员权限和生产 Redis/常驻队列尚未覆盖。


真实 Laravel 双进程单轮已验证余额完全抵扣的零金额 checkout：余额扣除、开通和流量重置一次，网关未调用，重复请求不延期；三层 50/30/20 返佣日志及余额各入账一次；购买者参与循环时全部返佣撤销，订单保持已开通、佣金待处理且仅保留一份核对记录。当前 236 项隔离检查、56 个冻结输入及11项执行器回归通过。仅验证该比例及 commission_balance 目的账户，其他比例、舍入政策和普通余额模式另验。 验收不启用生产支付，生产来源、命令注册与备份门禁保持。


真实 Laravel DatabaseQueue/Worker 已在专用 SQLite 队列表验证：CheckOrder 将任务序列化入队且不立即开通；首次开通异常释放任务重试、attempts 增长且业务事务无半次开通；真实 JobProcessed 事件核对两个独立 PID 各消费一个目标任务后队列清空，开通、流量重置和幂等消费者各一次。258 项真实隔离检查、57 个冻结输入与12项执行器回归通过，临时配置恢复。只覆盖有界数据库队列消费，不证明生产 Redis、daemon 信号/超时、failed_jobs终态、强杀或长期压力。 验收仅使用公开临时任务，不启动或修改生产队列。


真实 CouponService/Coupon 公开源码已验证两用户竞争全局限用一次的固定金额券：仅一张订单，券次数零，折扣与余额精确，输家无订单且余额不变。创建后的公开故障完整撤销券次数、余额及订单，重试成功。真实管理员 paid 控制器双进程确认只开通/重置一次，无网关调用且重复不延期；身份注入为夹具，不证明生产管理员权限链路。当前 289 项隔离检查、61 个冻结输入与13项执行器回归通过。 券范围不扩张到百分比折扣、个人/套餐/周期限制全部组合；未修改生产优惠券、账号或付款记录。
