# macOS supervisor 原生模块

本目录提供固定签名身份核验和单一子进程 owner。尚未接入 Runner、Dart、业务 relay 或系统代理事务，不是可启动的生产 helper 或完整发行包。

`Identity` 使用实际 Security SDK 和内核事实，分别核验宿主 bundle、helper 与 Core 的 Unique。PID 仅为定位值；出生、直接父属及 real/effective UID 由内核读取。最终产物清单为严格 canonical JSON；文件使用 no-follow、持 FD 摘要和路径重检。SDK 工作在意图锁之外，提交前重读整链 stamp，再检查 launch/generation/epoch；旧回调不能撤销新代。多进程读取不是原子事务，同 UID 注入和匿名管道来源不由此获得硬隔离保证。

`Owner` 通过 C `posix_spawn` 创建独立 Core 进程组；只有串行 `SupervisorLifecycle` 对指定 PID 执行 WNOWAIT 和精确 reap。原 5 秒启动预算包含 spawn 和身份核验；内核读取完成后再次检查期限。Stop/EOF 撤销权限并关闭 Core stdin；受控停止依次采用 EOF 4 秒、TERM 1 秒、KILL 2 秒。每次信号前核对 WNOWAIT 与捕获的内核身份。未知、漂移或失败保留所有权和首次错误，信号成功不代表资源完成；正常退出通过两次一致观察与一次精确 reap 确认。Core 后代、helper 被外部杀死、外部竞争 reaper 与脱组行为另验。

生产 `SealedCoreArtifact` 没有公开发行器；后续必须由固定身份模块完成发行，不能通过 Dart 或 stdin 提供期望路径、签名、UID 或进程组。一个 owner 只允许一个 launch，SDK worker 的跨实例限额、非阻塞 relay 和宿主 opaque handle 表由接线层负责。

## 验证

在已批准的本机 macOS arm64 PDEC 上执行：

```sh
python3 scripts/check_macos_supervisor.py --execute
python3 -m unittest discover -s scripts/tests -p test_check_macos_supervisor.py -v
```

验证器编译生产 SDK 实现，运行直接调用生产 authority 的 23 项 fake、生产 owner fake，以及固定公开 true/sleep 的真实子进程回收。`Tests` 中的身份 stub 和 C fixture 只在专用测试构建启用；真实 SDK guest、最终 App 签名、Dart 并发 reaper、业务流量和系统代理均需独立验收。回执在 `.test/three-platform-release/macos-supervisor-native.json`，每次实际执行另建独立工作目录。

公开独立签名App已通过真实Security SDK链矩阵：正常两角色身份链、错误locator、退出guest，以及清单篡改、Core移除签名、helper错误ID。证据见 `docs/validation/2026-10-07-three-platform/macos-supervisor-signed-sdk-validation.json`。该Core只等EOF，签名为ad hoc；不证明Mihomo业务、完整App或发行资格。
