# Xboard 服务端部署

## 主机与域名

运行主机为 NoSLA `216.23.116.56`，SSH 别名 `NOSLA`，Debian 13 x86_64。Xboard 目录 `/opt/xboard-test`，辅助订阅代理目录 `/opt/sub-mihomo`。流量经 Cloudflare 到 NoSLA Caddy，再到回环 Xboard 7001；访问链路无需 Vercel。

2026-10-08 新增独立开发验收账户 ID 5，24 小时有效、64 MiB、限速 5 Mbps、设备限制 1，零余额/佣金、无订单。既有用户、订单及佣金事务摘要不变；不调整公共注册配置。真实登录、账户、订阅、节点接口通过，返回 23 个节点；这些证据不代表邮件注册、邀请码归属、真实节点流量或支付验收。凭据通过受保护的本机工具注入，不入仓库；公开回执见 `validation/2026-10-07-three-platform/android-live-account-validation.json`。

| 域名 | 职责 | Cloudflare | 端口 |
| --- | --- | --- | --- |
| cloud.bingcn.site | 网页、注册、邀请、下载入口 | A → NoSLA，橙云 | 443；8443 兼容 |
| api.bingcn.site | API 与订阅 | A → NoSLA，橙云 | 443；8443 兼容 |
| origin.bingcn.site | 运维直连、源站验证 | A → NoSLA，仅 DNS | 443 / 8443 |
| cloud.microsoftnexushub.top | 既有客户端与备用入口 | A → NoSLA，橙云 | 443 / 8443 |

TTL 均为自动。根域名、通配符、www、邮件及指向其他主机的 api/panel/subadmin 不属于该服务。直连 origin 会公开源站 IP。

Caddy 使用既有 Cloudflare DNS-01 凭据续期公开可信证书。两区分别部署 `Bettbox NoSLA 严格 TLS` 配置规则，仅匹配上述橙云业务主机名，SSL 为严格；其他主机和全区默认策略保持原状。443/8443 均由 NoSLA 提供，未添加回源端口重写。

后台 `app_url=https://cloud.bingcn.site`，邀请链接取此可配置项。订阅地址随访问域名生成，未创建额外 subscribe_url 设置。引导池为 `https://api.bingcn.site` 和 `https://cloud.microsoftnexushub.top:8443`，在线由各入口 `/bootstrap.json` 提供，配置快照见 `docs/bootstrap/domains.json`。两入口共享同一主机，独立主机冗余及独立引导源尚未部署。

## 运行与持久化

- `/opt/xboard-test/compose.yaml` 管理 Xboard/Caddy。SQLite/WAL 位于 `.docker/.data`；插件、补丁、主题、日志和引导配置为绑定挂载；Redis/Caddy 使用 Docker 卷。Redis 卷为已存在外部卷，重建应用不得删除卷。
- CloudBridgeRelay 是 Xboard 插件，持久代码在 `/opt/xboard-test/plugins/CloudBridgeRelay`，静态页面在 plugins-public/CloudBridgeRelay，配置保存在 v2_plugins；与 Web、队列、定时任务共用 Xboard 容器。其文件摘要及配置表摘要已比对一致，订阅输出验证覆盖协议补丁；上游续费、充值及真实 VPN 不在该验证范围。
- `/opt/sub-mihomo/migration-compose.yaml` 管理辅助 Mihomo，保留配置、providers 与核心缓存。代理 7891/17890、管理 9095 只监听回环。
- 使用源实例确切镜像 ID，不随 latest 更新：
  - Xboard：`sha256:896e4926e0d7f18d223d58770590c74ab6f05ecb21f1b74ef5357ed20f44c676`
  - Caddy：`sha256:2051bb5b0a1e4845c4ca868d69f9d2dfa421bd5752c63cea9a937375894f6b55`
  - Mihomo：`sha256:19e2642914ba72a90b40edfe47fbab7fbdf820125fe7a2e7786a3c693ef7cb1f`
- 主机物理内存 929MiB、swap 2GiB；Xboard 限额 768MiB、内存加交换限额 1280MiB、CPU 限额 1；Caddy/Mihomo 各 128MiB。RESOURCE_PROFILE=minimal，`.env` 明确设置三个 HORIZON_*_MAX=1；队列和定时任务保持运行。
- Redis 使用 Unix socket 和 RDB，AOF 未启用；恢复实测加载 325 个未过期 key，保存状态 ok。
- `.env`、数据库、订阅配置、Redis 卷和证书私钥仅在 SSH 通道及远端权限受限备份中传递，不入仓库；不得回显凭据或订阅 URL。

## 运维与 CLI

```sh
ssh NOSLA 'cd /opt/xboard-test && docker compose ps'
ssh NOSLA 'docker exec xboard-test-xboard-1 php /www/artisan horizon:status'
ssh NOSLA 'docker stats --no-stream'
curl --fail --silent --show-error https://api.bingcn.site/api/v1/guest/comm/config
curl --fail --silent --show-error --resolve api.bingcn.site:443:216.23.116.56 https://api.bingcn.site/api/v1/guest/comm/config
```

网站等设置通过 `App\Support\Setting::set/save` 更新，以刷新 Redis 缓存；随后运行 `php /www/artisan octane:reload` 并核对真实 HTTP。此镜像的 supervisorctl 默认 socket 不可用。

本机已安装官方 cf CLI `1.0.0-beta.12`。本机入口 `~/.local/bin/cf-xboard` 经免密 SSH 临时读取 NoSLA 既有 DNS 令牌，仅注入 CLI 子进程环境并指定现有账户 ID；未新增 OAuth 授权或持久化令牌副本。

```sh
~/.local/bin/cf-xboard dns records list --zone bingcn.site --type A
~/.local/bin/cf-xboard dns records list --zone microsoftnexushub.top --type A
```

该凭据已验证 DNS 访问与证书签发，不能推定具有所有产品权限。新增权限需要独立评估，原始令牌不得进入模型上下文。参考 [官方安装与认证说明](https://developers.cloudflare.com/cf/get-started/)。

## 迁移证据与边界

2026-10-07：源 Xboard/Mihomo 停止并禁用自动重启，Redis SAVE 成功。冻结后归档 SQLite/WAL、绑定目录、Redis/Caddy/Mihomo 卷及主题；最终归档 SHA-256 为 `8429b7d83c8a4dedc9244323340b8c36040326dca9b43e4290d4e11149cc58f4`，传输后相同。目标首次启动前 34 张表内容摘要及 35 个绑定资源摘要全部一致。4 用户、2 套餐、2 订单、133 节点完整保留。

目标调整 app_url、引导池及更新时间、Caddy 443/8443 可信 TLS、资源上限、队列上限与代理回环监听。运行后唯一设置差异为 app_url，其他业务表摘要一致。首次 512MiB 启动出现 OOM/超时，调整资源并重建后 OOM=false、重启为 0。主机仍使用交换空间，未完成生产负载容量验收。

脱敏证据位于 `docs/validation/2026-10-07-nosla/`：

- state.json：镜像、摘要比对、配置差异、资源、容器状态。
- dns.json：四条记录的 IP、代理状态与 TTL。
- http-tls.json：四域名 443/8443 的网页/API/引导共 24 项公网 200，8 项公网证书验证。
- origin-tls.json：从腾讯云 SSH 环境直接连接 NoSLA IP，以四域名 SNI 验证 443/8443 的 8 项源站公开可信证书。
- source-manifest.json：冻结后的表行数与内容摘要、插件/补丁/主题/引导文件摘要。
- subscription.json：既有有效账户的两入口订阅 200，包含 proxies；无 token、节点响应或凭据。
- request-sample.json：4 并发、12 次公开 API 请求全部 200；短请求样本不能代替容量测试。
- 浏览器截图：DNS、严格 TLS 规则及注册页。

浏览器注册页已显示邮箱、密码和邀请码输入。没有提交新用户、真实支付、邮件、提现或设备 VPN；这些不属于迁移完整性证据。

## 回滚与旧主机

腾讯云 `170.106.143.23` 保留权限受限备份 `/root/xboard-migration-20261007/`。其 Xboard/Mihomo 已停止，Caddy 8443 只使用可信证书转发到 NoSLA，无数据库/队列写入。其他项目 nginx 仍占用旧主机 443，不能仅恢复 DNS 就认为回滚成功。

操作者须依序完成并逐项核对：

1. 先冻结 NoSLA Web、队列、定时任务等全部业务写入并等待活动任务结束；Redis 与 Xboard 同容器，在 Redis 仍运行时执行已验证的 Laravel Redis::connection()->save() 并核对 persistence 保存状态。随后正常停止整个 Xboard/Mihomo，确认最终 RDB 已落盘，再归档完整 SQLite/WAL 与 Redis 卷，保留双方现状，不能覆盖新数据。
2. 经 SSH 把目标最终一致的 SQLite 与 Redis 状态完整回传源，保留权限；恢复源运行配置，保持 app_url/引导池与将恢复的入口一致，核对完整性及内容摘要。
3. 源 Caddy 8443 已挂载四主机名可信证书 `/opt/xboard-test/certs/nosla/`。回滚当天先核对证书有效期、SAN 与真实 8443 TLS；复制证书不会在旧主机自动续期，失效时必须重新 DNS-01 签发。源预备模板位于 `/root/xboard-migration-20261007/Caddyfile.rollback`；它将上游切到回环 7001并保留 `/bootstrap.json` 静态路由；启动源 Xboard/Mihomo，用 `--resolve ...:8443:170.106.143.23` 验证。不要恢复旧自签证书配置。
4. 在两区创建仅匹配业务主机名的 Origin Rules，将 Cloudflare 回源端口设为 8443并保持严格 TLS，再将四条 A 记录恢复为源 IP；直连 origin 按 8443 验收。不得改动其他项目 443。
5. NoSLA Caddy 在 DNS 缓存窗口固定转发至 https://170.106.143.23:8443，transport http 指定 tls_server_name cloud.bingcn.site，保留正确的请求 Host 并保持证书验证；不能使用经过 Cloudflare 的业务域名作为上游，避免循环。源为唯一可写主节点。完成公网、订阅和队列验证后解除维护窗口。

源主机、源数据、镜像和备份未删除；过渡代理退役需在观察期确认后单独执行。


2026-10-08只读上游验收：三个CloudBridge上游源当前分别返回500、500、403；客户端与同步器两种声明UA结果相同，均无可解析节点/用量头。缓存快照显示过期、未耗尽，不能据此确认实时账户原因。NoSLA迁移完成不代表外部节点服务可用；需运营方安全核验或恢复有效上游订阅，禁止在聊天中提供带令牌链接。脱敏证据见 `validation/2026-10-07-three-platform/upstream-subscription-status.json`。
