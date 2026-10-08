# 账务固定迁移与迁移仓库原子执行

## 目标与事实

候选迁移 up/down 内部 DDL 事务已通过真实红绿；Laravel Migrator 在方法返回后独立写入或删除迁移仓库记录，失败窗口尚未封闭。生产支付候选未部署。目标是提供实际可安装的 billing:migrate 命令，将固定候选单文件、DDL 与迁移仓库写入/删除放入同一 SQLite 事务；不运行其它迁移，不删除已有账务证据。

## 所有权与边界

主控串行持有 overlay App Services/Billing/AtomicMigration、Console/Commands/BillingMigrate、真实 Laravel fixture/执行器、manifest、PDEC 与文档；未参与施工者独立复核。只使用 NoSLA 禁网只读临时容器及公开空库、历史行，不改生产库、网络或权限，不读取凭据。命令默认只输出计划，执行须明确 --execute；生产操作仍须停写、核对来源、备份和迁移记录。

服务固定迁移名称与规范路径，核对 Migrator 与目标连接一致；只接受顶层 SQLite 事务，未知嵌套状态拒绝。迁移仓库须已有，rollback 的最后批次只能含本候选；其它迁移的记录及文件保持。usingConnection 恢复默认连接，同一外层事务覆盖 Migrator 记录与内部 DDL/savepoint。

## 验收

使用真实 SQLite trigger 使成功记录 INSERT/DELETE 失败，先证明直接 Migrator 遗留状态，再验证生产 AtomicMigration 调用撤销 schema 与仓库变化。实际 Console Kernel 注册并调用 BillingMigrate，验证默认计划无副作用、执行/重复/回滚、旧账务证据拒绝、其它最后批次拒绝、错误输出不泄露异常文本。继续原业务回归、严格 runner 输入/完成项、overlay 摘要及 PDEC validate。独立审阅后 DIA/HLG 与一次提交推送。

强杀、掉电、真实生产 CLI 发现、停写和备份恢复另验，不把隔离候选等同上线。
