# 共享客户端与平台验收

## 代码与分支

Bettbox 使用 Flutter。页面、Riverpod 状态、Xboard API、邀请分享及收益展示共用 `lib/`。Flutter 支持 Windows、macOS 等原生桌面构建，插件仍须具备对应平台实现，见 [Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)。

项目保持单仓库、共享业务主线。短期功能分支用于隔离开发与评审，平台差异放在 `android/`、`macos/`、`windows/` 及有边界的平台实现中，不维护三套长期分叉的邀请、账户或商店业务。

| 能力 | Android | macOS / Windows | iOS |
| --- | --- | --- | --- |
| 邀请链接、二维码、收益 | 共享 Flutter 实现 | 共享 Flutter 实现 | 可复用业务/UI，尚无原生主工程 |
| 跳转型收银 | 嵌入式 WebView，并提供浏览器入口 | 系统浏览器 | 按 PRD 接 Apple IAP，不能沿用桌面收银作为完成方案 |
| 内核运行 | 原生动态库与 VPNService | 独立 core 进程和平台服务 | 需 Packet Tunnel 与独立内核桥接 |
| 系统集成 | Android 权限及生命周期 | Keychain/安全存储、托盘、代理、TUN、安装服务 | App Group、签名、隧道权限、后台生命周期 |

## 已落地的平台差异

`RedirectCashier` 只在 Android 创建 WebView 控制器。桌面使用 `url_launcher` 的 externalApplication；失败有本地化反馈。初始支付地址必须为 HTTPS 且不能包含 userinfo。Android 控制器在普通重绘时复用，地址变更时重新初始化并丢弃旧异步结果。QR 收银分支独立。

macOS 的 DebugProfile 与 Release entitlements 含安全存储插件要求的 `keychain-access-groups` 空数组；Team/App Group 未被硬编码。实际 Xcode 构建确认该 capability 要求开发证书；无团队时只能先做显式关闭 Xcode 签名的编译，不能认定 Keychain 登录持久化已验收。插件具体要求以锁定版本 flutter_secure_storage 10.3.1 的文档为依据，实际持久化仍须同签名标识的原生冷启动验证。

## 邀请业务验证

测试站点为后台 `app_url` 可配置项；客户端从 `guest/comm/config` 读取，不把该测试域名固定在邀请业务代码。公开网页路由 `/#/register?code=` 已验证可以预填邀请码。

`scripts/run_xboard_invite_check.py` 用已有 SSH 身份在指定 Xboard 容器的精确镜像上启动临时验证容器。执行器强制无网络、只读根文件系统、只读继承卷、移除 capabilities、禁止提权、限制 1 CPU / 256 MiB / 64 PID，并只给 `/tmp` 64 MiB 临时写入空间。脚本不输出认证响应、临时密码、邀请码、完整 inspect 或异常消息。

```sh
python3 scripts/run_xboard_invite_check.py \
  --ssh-target USER@TEST_HOST \
  --container XBOARD_CONTAINER \
  --report .test/invite-isolated-result.json
```

`verify_xboard_invite.php` 只读源 SQLite 的 DDL 和数字类型的公开佣金设置，在单进程 `:memory:` 中建立空业务库，并隔离缓存、邮件、队列和插件数据。实际经过 HTTP Kernel 创建邀请码与注册，实际调用 OrderService 算佣金及 `check:commission` 结算。付款完成状态由夹具模拟，不调用支付网关、`paid()`、`open()` 或真实邮件发送。

2026-09-22 验证通过：100 元订单按 10% 规则产生 1000 分佣金，`invite/fetch.stat` 从 `[1,0,1000,10,0]` 变为 `[1,1000,0,10,1000]`，顺序重复执行保持余额和流水不变。原始脱敏结果见 `validation/2026-09-22-invite-isolated.json`。

这不覆盖公网注册提交、邮件收件、下载引导、真实支付、提现或并发结算。服务端现有 `CheckCommission` 查询没有行锁，CommissionLog 没有 trade_no 唯一约束，不能承诺并发幂等；运营启用前须在 Xboard 服务端单独修复并以并发测试验收。

## 原生构建与设备验收

开发执行位置、工具版本、触发和产物见 `.pdec/README.md`。`scripts/validate_desktop.py` 默认只做前置检查，`--execute` 才编译；无开发证书时 macOS 另加 `--unsigned-macos`，其 manifest 记录请求关闭 Xcode 签名及实际签名事实，不能作为可分发安装包。Windows 构建产物只上传为保留 7 天的开发 artifact，不发布正式版本。

设备验收应使用相同候选 SHA：登录/退出与冷启动恢复、邀请码复制与实际扫码、系统浏览器收银跳转、订阅刷新、代理连接、TUN 权限、休眠恢复。Windows x64 和 macOS arm64 的结果不能替代 Windows arm64/macOS Intel 验收。Android WebView 的第三方 Cookie 与导航白名单约束也需单独补齐实机验证。

## iOS 工程工作包

用户已有 iPhone，开发者团队尚未准备好。当前仓库没有 `ios/` 主工程，且 `ClashCore()` 的非 Android 路径依赖桌面服务；不能仅生成 Flutter Runner 就视为完成移植。

1. 复用并扩展既有 `ClashHandlerInterface`，保持 Android/桌面实现行为，为 iOS 提供独立的连接、停止、状态、日志和统计实现；不能复用桌面进程启动方式。逐项检查本地插件：tray_manager、window_ext、proxy 属于桌面能力，需要保持平台隔离；flutter_qjs 和 code_forge 已声明 iOS 支持，仍需与主工程一并构建验证。
2. 建立 Runner 与 Packet Tunnel Extension，通过 App Group 交换必要配置；认证值使用可明确授权共享的 Keychain，不能把订阅凭据写入普通共享偏好。
3. 编译适配 iOS 的 Mihomo 原生内核，处理 PacketFlow、路由/DNS、内存上限、宿主与 extension 通信；现有 Go Android JNI 与非 Android空回调不能直接作为 iOS 实现。
4. Apple Developer 团队准备后配置 Bundle ID、App Group、NetworkExtension entitlement 与设备签名，验证真机联网、切网、锁屏、后台、断开/重连与异常退出。
5. 按 PRD 对接 IAP 商品映射及服务端交易校验、入账和返佣；再进行商店构建与分发验收。

前两项可独立准备，隧道签名与真机 VPN 属于后续验收条件。没有可运行的 Packet Tunnel 与签名证据时不标记 iOS 已支持。
