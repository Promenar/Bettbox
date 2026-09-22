# Bettbox 开发执行契约

## 授权与适用范围

用户在 Bettbox 邀请返利和跨平台适配任务中已允许“可配置项开发阶段允许按需调整”，并要求“继续……完成后续内容”。本契约在该项目开发授权内记录桌面编译、必要依赖恢复与验证；不扩大到生产部署、正式签名、商店上传、服务端资金操作或新的自托管执行主机。用户已说明有 iPhone，但 Apple Developer 团队尚未准备好。

## 工程与执行位置

工程为公开 GitHub 仓库中的 Flutter 3.44.9 / Dart 应用，内含 Go Mihomo core 与 Windows Rust helper。源码共用 `lib/`，当前候选分支为 `feature/m1-account-subscription`；不按操作系统建立长期业务分叉。

| 操作 | 执行主机 | 目标 | 入口 |
| --- | --- | --- | --- |
| macOS 编译验证 | 本机 macOS arm64，local | macOS arm64 | `python3 scripts/validate_desktop.py --target macos-arm64 --execute` |
| Windows 编译验证 | GitHub 标准 `windows-2022`，github-hosted | Windows x86_64 | `.github/workflows/validate-desktop.yaml` |

既有 `.github/workflows/build.yaml` 为发版 tag 构建入口，保留不变。验证入口单独产出开发候选，不执行发布。Windows 验证由当前 feature 分支相关文件的 push 或人工 workflow_dispatch 触发；每次使用事件绑定的确切 SHA，checkout 到工作区短目录 `s`。同步和构建触发不共用发版 tag。没有部署 Main/FNOS 的后台同步或任务执行服务。

macOS 保留现有 Xcode ad hoc 签名；不需要 Apple Developer 团队。Windows 验证不读取签名密钥。不同 SHA 的日志和产物以 GitHub run 区分，同工作区不并发执行脚本。脚本默认只检查环境并展示命令，显式 `--execute` 才编译。

## 工具、依赖与证据

- 固定 Flutter 3.44.9；macOS 使用已核验 Go 1.26.x、Xcode 与 CocoaPods；Windows 使用 Go 1.25.x、Rust 1.98.0、Visual Studio/CMake 原生工具链。实际版本由入口打印并核验。
- 使用 `pubspec.lock`、`core/go.sum`、Cargo.lock、Podfile.lock、Package.resolved。构建不运行 pub upgrade / go mod tidy / flutter clean；锁文件变化直接报告失败，依赖更新另行审阅。
- core 进入 `libclash/<平台>/`；Windows helper 的 IPC 校验值由同次 core SHA256 生成。Flutter 构建使用该摘要。
- 本机产物位于 `build/macos/Build/Products/Release/Bettbox.app`；Windows bundle 位于 `build/windows/x64/runner/Release`。入口检查文件存在并输出 SHA256。原生编译成功仅证明构建能力，实际代理连接、系统浏览器、Keychain 冷启动及权限仍须设备验收。
- Windows job 有有限超时，runner 随 job 回收；不使用家庭自托管 Runner，不向候选代码传入生产凭据。缓存按平台与依赖锁隔离；开发产物保留期由 workflow 声明。
- 本机依赖由现有 Flutter/Go/Cargo 缓存和 CocoaPods 管理，不自动清理用户缓存。一次性构建不开放服务端口；停止可中断构建进程，清理仅针对明确的项目生成目录。

## 平台范围与回滚

只登记 macOS arm64、Windows x86_64 原生编译，不把一次架构构建外推到 macOS Intel 或 Windows arm64。iOS 需要独立 Packet Tunnel 工程、内核桥接、App Group、签名和 IAP 验证，尚未登记可执行构建操作。

开发候选通过 GitHub artifacts 或本机文件交付，不传送到生产服务。生产目标、健康检查和发布回滚均未启用。回退本任务提交即可恢复客户端与构建配置，既有 tag 发版入口持续保留。面板的只读/隔离集成测试属于既有服务诊断，不通过此契约授权真实用户或资金变更。

变更范围为构建脚本、验证 workflow、契约及相关项目文档；客户端差异与测试另见 `docs/PLATFORM_VALIDATION.md`。执行前运行用户级 PDEC `validate --root`，要求 `execution_ready=true`；契约所引用的脚本或锁文件变化后需重新核对授权范围和摘要。
