# macOS supervisor 原生模块

本目录提供固定签名身份核验、独占Core回收、非阻塞relay及宿主原生ABI。生产helper与宿主ABI已在真实Mihomo签名夹具中完成握手、只读动作和停止验证；Runner已编译接线，Dart应用路由、helper打包和系统代理事务尚未联合接入，不是完整发行包。

`Identity` 使用实际 Security SDK 和内核事实，分别核验宿主 bundle、helper 与 Core 的 Unique。PID 仅为定位值；出生、直接父属及 real/effective UID 由内核读取。最终产物清单为严格 canonical JSON；文件使用 no-follow、持 FD 摘要和路径重检。SDK 工作在意图锁之外，提交前重读整链 stamp，再检查 launch/generation/epoch；旧回调不能撤销新代。多进程读取不是原子事务，同 UID 注入和匿名管道来源不由此获得硬隔离保证。

`Owner` 通过 C `posix_spawn` 创建独立 Core 进程组；只有串行 `SupervisorLifecycle` 对指定 PID 执行 WNOWAIT 和精确 reap。原 5 秒启动预算包含 spawn 和身份核验；内核读取完成后再次检查期限。Stop/EOF 撤销权限并关闭 Core stdin；受控停止依次采用 EOF 4 秒、TERM 1 秒、KILL 2 秒。每次信号前核对 WNOWAIT 与捕获的内核身份。未知、漂移或失败保留所有权和首次错误，信号成功不代表资源完成；正常退出通过两次一致观察与一次精确 reap 确认。Core 后代、helper 被外部杀死、外部竞争 reaper 与脱组行为另验。

`SealedCoreArtifact.prepareSupervisor()` 只从固定supervisor角色的真实SDK事实发行，保留Core与清单FD并在spawn前重检。Host只从固定宿主角色取得helper路径；Dart/stdin不能提供期望路径、签名、UID或进程组。

`Relay` 使用单SDK worker、有界mailbox及nonblocking poll，分别限制4KiB控制帧与10MiB业务帧。ACK授予第一帧许可，连续credit只证明上一帧已写入Core，不代表业务完成。每方向只有一个完整帧缓存；Core HUP在背压时保留，排空缓存后读取到明确EOF。停止丢弃已读缓存、半帧或未读输入时固定失败31；正常0只证明本代Core已确认回收，不承诺取消后的业务结果交付。

`Host` 通过六个固定ABI发行不透明handle，SDK在单worker中运行，内核提交核对后再次检查原期限。撤销保留停止出生记录；缺Core记录时不得用helper消失推断Core完成。未发行启动路径的预检失败只在SDK实际返回后释放槽。Flutter薄桥由Runner窗口持有，Identity与Host六份Swift源进入Runner Sources；Debug身份不同于生产身份链，不用于生产链验收。

`lib/clash/supervisor` 的Session持有唯一helper Process与退出Future，先撤销再关闭stdin，确认EOF、exit0与native出生消失后才清除owner。最多8项待发送动作，异步结果消费者的资源限额由应用接线负责；该Session尚未替换ClashService现行启动路径。

## 验证

在已批准的本机 macOS arm64 PDEC 上执行：

```sh
python3 scripts/check_macos_supervisor.py --execute
python3 -m unittest discover -s scripts/tests -p test_check_macos_supervisor.py -v
```

验证器编译生产 SDK 实现，运行直接调用生产 authority 的 23 项 fake、生产 owner fake，以及固定公开 true/sleep 的真实子进程回收。`Tests` 中的身份 stub 和 C fixture 只在专用测试构建启用；实际SDK进程链由独立签名fixture验收；完整Flutter方法通道、真实Mihomo、业务流量和系统代理另验。回执在 `.test/three-platform-release/macos-supervisor-native.json`，每次实际执行另建独立工作目录。

公开独立签名App已通过真实Security SDK链矩阵：正常两角色身份链、错误locator、退出guest，以及清单篡改、Core移除签名、helper错误ID。证据见 `docs/validation/2026-10-07-three-platform/macos-supervisor-signed-sdk-validation.json`。该Core只等EOF，签名为ad hoc；不证明Mihomo业务、完整App或发行资格。

生产接线验证见 `docs/validation/2026-10-07-three-platform/macos-supervisor-integration-validation.json`：32项原生步骤与最终host定向回归、17项Session测试、155项Flutter全量测试和静态分析通过。提交期限、SDK后出生变化、背压缓存取消及HUP残留输入均有实际失败证据及修复验证。公开Core签名矩阵验证真实六ABI、helper/owner/relay、握手与credit/result，正常退出及native确认消失；manifest篡改和helper错误ID拒绝，检查时无该夹具残留进程。签名为adhoc，Core不是Mihomo。

`Tests/SignedProduction/runner.py` 使用冻结actual源及唯一输出目录，已有目录拒绝覆盖；PDEC登记的输出名仅用于对应执行。新的运行需登记新的输出名并核对来源，不能复用旧回执宣称新版本通过。

真实Go验证入口为 `Tests/SignedProduction/real_go_runner.py`，固定读取任务Core并校验预登记SHA，签前冻结字节，使用生产helper/native host发出 `getIsInit`，严格核对真实result、credit、exit0与native出生消失。仅验证未初始化状态，不加载账户或配置，不启用代理。Core源码与helper/host源分别绑定；Python拒绝测试覆盖摘要错误、产物替换和符号链接。执行证据见 `docs/validation/2026-10-07-three-platform/macos-runner-real-go-validation.json`。
