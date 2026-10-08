# Laravel 数据库异步队列与补偿验收

## 目标与边界

在既有 NoSLA 禁网只读隔离容器中使用 Laravel DatabaseQueue 与 Worker，不以 dispatchSync 或手动调用 job.handle 代替异步消费。CheckOrder 实际命令将公开订单补偿任务序列化入独立 SQLite 队列表；注入开通故障后验证任务释放重试且业务事务不留下半次开通，随后两个独立进程消费重复任务，核对一次开通、一次流量重置和一次幂等消费。

主控独占新 laravel_queue_check.php、入口、精确白名单、执行器回归、PDEC 与文档。只增加公开临时队列表与配置；不接生产 Redis、队列进程、数据库或凭据，不改变生产 job/command。Worker 构造、runNextJob、WorkerOptions 和 DatabaseConnector 依据既有镜像 vendor 只读源码核验，消费轮次有界，不启动常驻 daemon。

## 验收

队列配置临时切换并在 finally 恢复。实际任务 payload 匹配目标公开 tradeNo 和 job类，验证入队且未开通、第一次异常释放且 attempts 增长、开通/余额/流量日志不变；重复目标任务由双进程 Worker 消费，继承现有独立连接、共同起跑与重叠断言，最终任务清空且业务一次。执行器要求异步队列证据标签，负例缺失时拒绝。真实隔离运行、独立只读审阅、DIA/HLG 后提交推送。

该验收只覆盖数据库队列的有界消费和异常释放/恢复，不证明生产 Redis、daemon信号与超时、failed_jobs终态、强杀、长期压力或生产运维已就绪。优惠券、管理员付款、真实商户与三端VPN/签名/界面仍待验收。
