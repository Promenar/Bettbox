# 付呗真实插件管理器隔离验收

## 目标与范围

在既有NoSLA禁网、只读公开源和独立SQLite容器中验证Xboard真实PluginManager的目录解析、安装、默认禁用、显式启用、支付类型发现、禁用及卸载。真实商户、生产插件目录、生产数据库、秘密、付款、公网和部署不在本工作包内。主控独占Laravel隔离入口、执行器白名单、关联回归、PDEC摘要及文档；完成后由未施工者复核。

## 已核实输入

真实PluginManager、AbstractPlugin、HookManager和PaymentService在现有公开源缓存中；原验收用PluginDiscovery替代发现。真实App\Models\Plugin已从NoSLA现有容器只读获取，SHA256为20ce2526f5f0382c3a97fbd27266725fb658edc4fe6b5ad7c5abdbe26bd42d0a，缓存文件只读。付呗config.json使用小写fubei，实际类命名空间由Str::studly解析为Plugin\Fubei；支付方法名Fubei与插件码fubei职责不同。

## 实施合同

1. 将公开Plugin模型和候选config.json加入精确输入白名单，源站Hash核对及PDEC输入摘要更新；不扩大容器网络、挂载、内存或PID边界。
2. 在唯一临时应用目录创建候选插件树，只复制已冻结的公开文件；独立空v2_plugins表及真实模型承载生命周期，不操作真实插件目录。验证路径与配置来自该树。
3. 实际管理器安装后应有一行默认禁用、enabled=false；启用管理器但全局业务开关关闭不得注册收款方法。显式全局开关与支付方式开关分别验收，插件码匹配真实PaymentService。
4. 禁用/卸载后核对发现结果和持久状态，区分同请求残留Hook与新请求生命周期。真实发现和class加载来源必须分别记录；若仍使用ClassMap或子类传输替身，不能宣称完整动态文件发现已验收。
5. 保留既有账务、并发、队列、优惠券和管理员测试；新失败先确定是候选还是fixture缺失，不修改上游管理器或付款规则来使测试通过。

## 验收与回滚

运行执行器公开工具回归和PDEC validate，再执行既有run_laravel_isolated.py --execute；结果新增明确检查标签、实际类与目录证据，全部原标签保持。独立审阅后记录diff、测试、源码摘要和剩余夹具。没有生产激活或迁移；失败容器按现有归属/退出合同清理，源码可回退相关测试提交。

## 当前状态

实现及真实隔离验收通过：task28c0ff8047d947389e363db80c58d93f，300项检查、64个冻结输入，源码未变、清理确认；13项执行器回归通过。独立审阅定位可选Provider缺席探测与fixture拒绝门禁冲突，精确允许该类探测后启用通过。两次诊断失败均清理确认，失败回执的source_unchanged=false表示未执行复核，不能判为源码漂移。

仅证明目录解析与真实类发现，ClassMap预加载没有验证目录require回退；新请求Hook清空没有验证同请求残留闭包。后续账务使用原PluginDiscovery和网关替身，生产部署、商户支付及真实管理器贯穿checkout待验收。测试邮箱验证码请求仅发送一次，HTTP200/data=true；本机验证码文件仍为空，未提交注册。
