# 版本变更记录 (CHANGELOG)

## 2026-10-08 — 后台检查式监听关闭接线

- Android后台停止监听使用invokeAction的检查式Go动作，confirmListenerStop只接受同次id、stopListener方法、整数code=0与严格data=true；失败、畸形、缺字段或异次回执均不能确认成功。GlobalState后台与ClashCore公开停止入口对false阻断本地状态清理；ClashCore.withInterface供隔离行为验证，ClashLibHandler.withLibrary初始化测试库但不替换生产单例。生产默认库名libclash.so保持一致。
- 真实ClashCore红例1失败、修复6项定向回归通过；本机darwin-arm64实际Go c-shared库经生产ClashLibHandler连续两次停止消费成功回执，库摘要在执行前后保持一致；237项Flutter完整测试及静态检查通过。非移动cgo文件lib_non_mobile.go与!android && !ios && cgo条件一致；其移动平台和非cgo分支仍各自独立。

## 2026-10-08 — shutdown关闭失败传播

- shutdown监听失败传播已接入生产handleShutdown：runLock内关闭新监听准入并调用StopListenerChecked，未确认即返回false，保留isInit与失败对象，不执行executor清理。Android ClashLib.shutdown使用completeShutdown，关闭false或异常不销毁，关闭成功后等待destroy；destroy仅在Service回执严格true时成功。Go公开登记监听的实际红例证实原失败吞没、初始化状态丢失及重试责任丢失；固定源版本的失败/成功与stop action回归通过。该改动不证明executor、provider、controller、TUN drain或全部runtime资源退出，不提供engine退出资格。

## 2026-10-08 — Android普通停止完成确认

- Android普通stop/stopVpn响应等待同次native工作门禁中的TUN关闭、平台资源关闭和匹配代次的STOP提交；失败返回false并保留阻断与未确认绑定责任。Dart两个普通停止包装器对false/null抛出现有本地化错误，后台引擎显式调用Vpn.stop，运行时间与偏好只在普通停止确认后更新。JVM屏障回归与真实release Kotlin工程编译通过；Dart实际包装器红例复现2项失败、修复6项通过，完整Flutter测试225项通过。smartStop、typed owner、关闭后engine ACK及新APK设备验证尚未完成。调用方等待响应期间暂留engine，不能据此宣称完整关闭或发行可用。

## 2026-10-08 — Android实际VPN授权路径

- Android实际权限启动路径使用进程内动态请求码与同次弹窗共享结果；拒绝、无Activity、prepare/launch异常及正常detach/engine退出逐请求一次完成false。配置变更保留在途请求并向新Activity重新注册监听，迟到旧结果不完成新请求；授权成功先核验原始intent再初始化service engine。冷恢复后的权限请求切Main，prepare异常不再被当成授权成功。生产controller公开JVM回归及独立复审通过，实际Android release Kotlin工程离线编译退出0且源码不漂移；新APK安装、设备旋转/权限弹窗及真实VPN流量另验。

## 2026-10-08 — Android JNI检查式释放

- JNI注册释放回调增加固定状态，Go拒绝未确认结果并保留State责任；线程附着失败安全短路，分离未知粘滞保存，Protect/Resolve异常与空环境不触发非法Java调用。
- 生产函数表17场景、既有JNI/配置桥26场景、Go状态race及同次Android ARM64 ABI/链接通过，独立复核关闭null状态合同缺陷；真实JVM/CheckJNI、TUN reservation、唯一owner及新APK另验。

## 2026-10-08 — Android启动报告与macOS启动准入

- Android生产State增加最终启动报告；修复混合关闭故障下runtime误清、首错覆盖及Shutdown panic后重复伪成功。初始8项及混合6项失败复现，定向、race、core与Android原生编译通过；唯一owner及设备接线另验。
- macOS开发候选严格验签通过但实际启动因缺少有效profile被系统拒绝。封装器在未建立profile授权链时拒绝完整候选非空权利，并核对签后实际权利；24项回归通过。真实Keychain权利保持，不将签名成功升级为启动或发行通过。

## Android同步配置接口与原生回执

- 新增Go版本核验、初始状态暂存、同次options复制及未知结果阻断；增加JNI同步接口与严格Kotlin回执解析。
- 修复空路由列表复制改变JSON形态的兼容问题，增加生产早失败与原生函数表回归。
- 验证边界：未接唯一Native owner及TUN版本核验，未安装新发行包；iOS保留开发版，Android/macOS优先交付。

## 2026-10-08 — 配置准备与发布边界

- 生产setup先复制输入并解析局部候选，成功后才发布；失败保留最后配置和默认探测URL，nil参数固定拒绝。七个场景在修复前失败、修复后通过，含复制/数值语义的十三场景及core包回归通过；Android ARM64实际Go共享库和生产JNI编译链接通过。
- Mihomo解析中的临时全局、geodata、fake-IP持久缓存和候选资源副作用已纳入Android提交合同；不能将ParseRawConfig当纯校验或宣称全回滚。统一owner和设备验收另行完成。

## 2026-10-08 — 生产停止结果确认

- Go监听停止入口接入已有检查式关闭，不再忽略关闭错误并始终返回true；失败对象保留供显式重试，单轮去重并继续关闭其它资源。真实handler/action八场景修复前失败、修复后通过，core包回归通过；不表示完整runtime或Android设备停止验收。
- Android初始setState采用STAGED合同，首个setup消费同owner的desiredState；HTTP无headers兼容、epoch/revision和有界内存receipt边界纳入联合实施计划，生产接线待验。

## 2026-10-08 — macOS 开发签名候选

- 完整应用候选使用现有唯一Apple Development身份签名，10个嵌套框架及宿主严格验签通过，Core/helper签后字节保持不变；20项封装工具回归通过。证书Team按指纹匹配叶证书OU，不从CN后缀推断。
- 默认ad hoc模式保持兼容，旧候选目录保留备份；候选未公证，正常应用、Keychain、系统代理和有效节点流量另验。回执：`validation/2026-10-07-three-platform/macos-development-signing-validation.json`。

## 2026-10-08 — Android、macOS 交付验证

- macOS空受保护journal恢复免SC锁，读取/所有权未知保持失败；真实非阻塞SC权限探测与64项核心回归通过。Host迟到SC完成独立门禁经实际红绿及独立复核，未知不允许释放owner。
- macOS Host使用同份SC事务核心；显式恢复期间新启动立即拒绝，恢复未知不清洗旧owner。实际SDK编译、原生夹具和7项工具测试通过，完整Runner及真实系统代理另验。
- macOS Session全部收尾经过无proof恢复门禁，恢复冲突保留Core/stdin；底层恢复单次操作保持到真实完成，不由调用者超时清洗。24项Session、5项严格解析与独立回审通过，Flutter全量200项通过；正常Application接线与真实系统配置另验。

- f881880 Android ARM64正式候选构建、签名、16KiB产物检查及模拟器安装回读通过；冷启动、开发账户恢复及直连模式本机HTTP代理/浏览器HTTPS通路通过，两轮停止均确认TUN与监听释放；上游协议流量另验。独立回执为 `validation/2026-10-07-three-platform/android-f881880-build-validation.json`。
- Android真实完成回执与跨engine配置owner联合接线计划已形成；现有布尔受理返回不能作为启动/停止完成依据。
- macOS schema4核心加入专用入口能力、独立持久/运行未拥有字段摘要及严格旧journal兼容；SOCKS摘要与恢复提交前外部修改缺陷经失败回归修复，61项Swift测试及独立回审通过。正常应用接线与真实系统代理另验。

## 2026-10-08 — 原生FD所有权构造合同

- 新增受限的所有权感知监听器入口，保留原Stack和首次清理错误；缺失采纳回调在资源操作前拒绝，8项Go回归及独立复审通过。Android完整接线另验。
- 三个上游订阅在客户端与同步器UA下均返回500/500/403，实时有效期和认证字段无法核对；缓存均显示过期。已请求后台核验，不续费或改变账户。

## 2026-10-08 — 受限同源协议诊断

- 新增不改变系统网络的AnyTLS/Hysteria2受限探针及安全执行器；7项Go和3项执行器回归通过，字段别名与异常进程收尾缺口经独立审阅修复。
- 真实4节点探测均失败，Hysteria2分类为authentication；尚未确认上游根因，Android/macOS候选不升级为可用发行版。

## 2026-10-08 — Android VPN 实机路径诊断

- 订阅节点地域呈现、系统VPN授权与隧道建立、直连请求以及停止恢复通过；默认代理和香港全局请求失败，协议认证/数据通路待定位，候选未升级为可用发行版。
- 已排除候选Kotlin protect同名递归、旧腾讯IP端点及本地UUID误替换假设；三个TUN/JNI失败处理缺口列入独立复现计划。

## 2026-10-08 — 账户输入法配置

- 登录、注册、找回密码的邮箱与密码，以及邀请码输入关闭纠错、候选建议和智能字符替换，避免输入法改写身份标识；密码显示时保持限制。
- 8 项输入法通道回归修复前失败、修复后通过，完整 Flutter 192 项通过；正式 Android 候选已构建安装，原生纠错关闭、真实登录、64 MB 配额及冷启动恢复通过，VPN/邀请注册/支付另验。

## 2026-10-08 — Android 真实账户验收准备

- NoSLA 新增独立短期开发账户，零余额/佣金、无订单；既有用户、订单及佣金内容不变。
- 真实登录、账户、订阅与节点接口通过，返回 23 个节点；客户端登录、冷启动及 VPN 流量待验收。

## 2026-10-08 — Android正式签名候选

- Android arm64正式签名APK构建、单一发行证书、核心一致性与16KiB对齐检查通过，保存固定源码候选。
- Pixel_7安装及回读摘要一致，首页/登录页显示正常，观察范围内无Java/JNI/native崩溃；完整账户、订阅、VPN与支付发行验收另验。

## 2026-10-08 — Android Google Maven别名

- 根据真实正式构建拒绝事件与Google官方仓库文档，将maven.google.com精确HTTPS主机纳入项目专用依赖通道。明文、其他端口、子域及未知主机继续拒绝。
- 失败回归先复现，当前94项构建与网络测试通过；正式APK仍需重新构建及验签。

## 2026-10-08 — Android构建拒绝诊断

- 任务代理增加固定拒绝类别，区分非CONNECT、非法authority与未批准域名；不保存任意请求内容，不扩展联网白名单。
- 失败回归先复现，构建工具与网络93项测试通过；正式APK验收仍需真实构建结果。

## 2026-10-08 — macOS受保护所有权记录

- 新增schema3 canonical编码、固定native路径、权限/ACL/inode检查及跨进程flock；原子发布与目录同步失败保留恢复边界。
- 首次创建及跨实例重开的父目录同步缺口通过实际失败回归复现并修复；46项Swift测试通过。真实系统代理配置未写入，App接线与流量待验收。

## 2026-10-08 — macOS SystemConfiguration候选

- 新增真实SDK后端与受限字典合并，HTTP/HTTPS事务保留SOCKS；schema3拒绝旧2自动恢复。
- 真实只读验收发现并修复stored零值端口、空bypass兼容；新intent保持严格校验。34项Swift测试通过，系统配置未写入；native授权、生产journal及App接线待验收。

## 2026-10-08 — macOS预检失败恢复

- 修复未发行reservation的预检拒绝导致客户端无法重试：通过原生同代撤销证据恢复，保留迟到worker和所有已发行/未知进程所有权。
- 失败测试先复现；184项Flutter测试、静态分析及原生host测试通过。实际Application/Session覆盖重试，native和transport采用fixture；正常应用及系统代理尚未验收。

## 2026-10-08 — macOS应用传输与有界RPC

- macOS ClashService使用生产Application/Session/RPC，移除该平台旧控制socket、直接Core回收与fallback。
- 请求、重启、结果和异步事件有界；发送与回包双确认，统一deadline及独立cancel；失败通知不能清洗未知消费者。
- 六项失败复现闭合：RPC/readiness三项、挂起sender两项、真实事件派发中途throw一项；独立回审通过，181项全量测试及静态分析通过。
- 真实Flutter通过同一Application/RPC两代getIsInit与32个公开child退出；正常main、SC、安全存储与有效业务流量待验收。


## 2026-10-08 — macOS真实Flutter会话验证

- 新增独立Flutter探针，真实生产helper/Go Core连续两代getIsInit与32个公开child退出验收通过；正常App、源码和锁保持一致。
- 独立审阅闭合未跟踪探针输入摘要缺口，新增严格标记与链接/漂移回归。
- 系统AMFI拒绝带受限entitlements的ad hoc探针；仅探针签名省略权利，正常应用Keychain和发行签名独立验收。


## 2026-10-08

- 将arm64生产helper及身份清单接入Xcode和共享构建入口；完整Release构建、10个framework与宿主最终开发签名/嵌套严格验签通过。成功清单链接写入缺口已建立红例并修复；40项macOS工具、23项桌面工具及156项Flutter测试、静态分析通过。完整Flutter新会话、系统代理及发行资格另验。

- 将固定宿主通道、Host/Identity源码与桥接头接入macOS Runner；真实Mihomo签名链通过握手、getIsInit及原生退出确认，9项Python拒绝/输出测试通过。helper封装、完整Flutter会话与系统代理另验。

- 纳入macOS production helper/relay、宿主六ABI和Dart Session。提交期限、SDK后出生变化及背压/EOF丢数据缺口已建立红例并修复；32项原生步骤、最终host定向回归、17项Session测试、155项Flutter全量测试与静态分析通过。
- 生产helper与真实host ABI的公开签名进程链矩阵通过：握手、credit/result、exit0/native出生消失；清单篡改及错误签名ID拒绝。公开Core不是Mihomo，完整App/Go业务/SC与发行另验。

- macOS公开独立签名host/helper/Core的真实Security SDK矩阵通过；正常两角色链与错误locator/退出guest、三项静态篡改拒绝分别验证，执行签名SHA与基线独立记录。Mihomo业务、Dart/SC和发行签名另验。

- 纳入macOS supervisor原生身份与独占回收模块及可重复验证入口；身份提交前整链stamp与启动期限缺口均已失败复现并修复。实际SDK编译、23项身份fake、owner fake及公开true/sleep回收通过，客户端与签名进程链另验。

- 集成macOS Go专用入口的私有会话能力、端点代次与配置失效门禁；36项main回归及25项HTTP race通过，宿主/系统代理仍待接线。
- 增加StopListenerChecked资源关闭API，错误保留对象并继续其他关闭；5项含真实loopbacksocket的race通过，Android平台消费者另验。

- TCP/UDP隧道构造器先校验目标再绑定，防止无效目标错误路径遗失socket；生产回归修复前失败、修复后race通过。
- macOS无Dart辅助进程父属隔离的最小实测通过；生产签名身份、真实核心relay和系统代理仍待接线。

- Android配置协调候选的30个JVM场景通过，覆盖配置副作用与启停串行、撤销和粘性恢复；真实同步JNI、监听器完成事实及Dart接线仍待实施。

- 当前Dart退出线程竞争回收原生child经真实短时夹具复现；macOS原生独占回收方案需统一或隔离父属，未把纯Swift证据标为Flutter生产通过。

- Android 联合候选修复旧Doze回调跨lease影响新连接的问题；23个JVM协调场景、权限归属夹具与20个Go helper/静态接线race测试通过，实际Android/Dart整包接线另验。
- macOS native身份候选SDK编译与9项fake通过；真实launch暴露Foundation独立child进程组，创建/回收合同进入专门诊断，未标记真实guest或完整发行通过。

- macOS core 使用固定 ad hoc 身份最终签名，签名后的文件重新绑定，验签与摘要期间拒绝漂移；共享打包入口和bundle验证核对身份清单，真实签名及34项Python回归通过。完整App、宿主身份与发行资格另验。
- Android协调候选15个JVM生命周期场景编译执行通过，实际Service/JNI整包接线和smart行为尚待完成。

- 增加Android启停资源基础逻辑与回调引用门禁；关闭失败保持所有权，排队回调取消，首次错误粘性保存。基础包race通过，原生整包接线另验。

- Android 快速配置预检在初始化或状态解析失败时立即终止，保留固定错误且只发送一个结果；生产 helper 短路回归经 race 验证。
- 修复客户端状态JSON部分提交、共享列表/指针与并发数据竞争；统一深复制快照，action失败回传固定字符串。4项状态race和22项共享core测试通过，原生启动失败链另验。

- 增加macOS owned-child Go匿名管道入口、单调握手期限与代次隔离；21项普通协议测试及5项真实child退出fixture通过，原生身份和Dart/系统代理接线尚未完成。


- 新增 macOS 专用无代理凭据解析 HTTP/CONNECT 入口与23项实际race测试，包含大文件、EOF、pipeline、停止证据及默认入口认证回归；宿主与系统代理尚未接线。
- Android ea2aa0a 调试APK动态依赖与模拟器起停通过；真实流量和失败路径单独验收，未标记发行可用。

## [Unreleased] - Android 设备加载与签名检查 (2026-10-08)

- JNI 链接对无 SONAME 的 Go 核心声明 `IMPORTED_NO_SONAME`；APK 门禁要求 `libcore.so` 依赖 basename `libclash.so`，拒绝构建路径及不一致的 ELF 动态段映射。
- 项目发行密钥与回执保持 0600。系统登录钥匙串按同用户、无他人写权限检查，读取仍通过固定 security 条目；不修改系统权限或 ACL，保留证书锚。
- Android 调试候选实际安装、邀请生成与网页邀请码预填通过；VPN 启动暴露路径依赖崩溃，修复后的完整构建和设备验收独立记录。

## [Unreleased] - 三端发行基础安全 (2026-10-07)

- API 域名池仅接受无凭据的 HTTPS 根地址；远端引导过滤不安全地址，域名池重排保留当前连接。
- API 与引导请求关闭自动重定向，HTTP 非成功状态不被成功包络掩盖；日志和连接错误不输出订阅凭据。
- Android release 缺少签名配置、原生构建缺少内核或头文件时中止，避免生成错误候选。
- 共享 Flutter 106 项测试与新增 4 项实际 IO 重定向回归通过；静态检查通过。三端完整设备与服务端交易验收另行记录。

## [Unreleased] - 原生核心与服务端事务候选 (2026-10-07)

- iOS 增加 Runner 原生桥、独立 PacketTunnel、App Group 配置快照和内嵌 Mihomo C ABI。设备/模拟器arm64核心与真实SDK类型检查通过，完整 arm64 模拟器应用编译、安装、首页/登录/注册导航与7项原生单元测试已验证，真机VPN独立验收。
- 发行交付优先 Android、macOS；iOS 保留开发版并研究符合 Apple 用途约束的发行方案。
- 配置快照核验完整资源文件集合及运行副本，实际复制预算有界；停止回调独立截止，控制消息保持单在途。
- Dart 接入系统VPN状态、资源清单、模拟器离线能力；成功启动请求不提前显示连接，停止意图贯穿启动预检与配置发布。
- 支付与返佣候选按线上订单源码适配SQLite事务、支付快照、唯一流水、佣金幂等和持久事件恢复；隔离真实SQLite多进程测试通过，真实Laravel隔离集成通过，真实交易待验收，生产付呗禁用。
- Android 增加任务独立Gradle目录、进程清理与核心/APK来源核验；用户允许本项目官方依赖任务级解析及本机正式密钥创建，正式 Android 签名密钥已安全创建，任务官方CONNECT、早期JVM注入与正式签名接线通过142项工具测试，实际TLS与Gradle发行包下载通过；实际APK/签名仍待验收。慢请求头与带空格Java路径清理缺陷经历史版本失败/当前版本通过的隔离复现验证，清理失败保留主失败原因，候选枚举排除受保护的非Java进程、Java读取失败保持拒绝。QuickJS声明仓库限制到Google/Maven Central，版本不变；Gradle发行文件与8.14 Wrapper分别固定官方校验和，4个Wrapper文件纳入来源冻结；项目内完整性匹配的发行ZIP可独立预置，33项缓存夹具通过，不复用Maven/编译缓存。
- Android真实Gradle配置、官方ZIP复用与退出清理通过；定位ARM64任务误构建armeabi-v7a，core原生模块按Flutter目标参数限制ABI，保留缺核心拒绝，真实修复APK待验收。
- Android应用打包按显式Flutter目标过滤ABI，防止ARM64候选包含其他架构插件库；真实APK已生成但最终ABI验收拒绝，12个ARM64库16KB对齐通过，完整修复构建待验收。split-per-abi路径由Flutter管理App过滤，保留core原生过滤。
- Android库及应用保留已去调试信息的Go核心原字节，避免AGP再剥离破坏精确来源哈希；真实NDK复现确认转换根因，修复完整APK待验收。
- macOS 增加串行系统代理事务核心，实际Swift编译与23项fake后端测试通过；真实系统配置、持久journal和App接线独立验收。

## [开发环境] - 本机平台分工与 iOS 模拟器 (2026-10-07)

- 本机负责 Android、iOS、macOS 开发调试，Windows 原生调试使用 Windows 环境，保留现有 Windows CI。
- 安装官方 iOS 27.0（24A434）ARM64 模拟器运行时，iPhone 17 启动及 Flutter 设备识别通过，验证后关闭。
- Android 日常开发共用已有 AVD，其他版本用于兼容性回归；保留 Nexara 使用的现有设备。未创建 Bettbox iOS 工程或执行支付/VPN 验收。

## [运维] - NoSLA 服务端迁移 (2026-10-07)

- Xboard、SQLite/Redis、CloudBridgeRelay、主题补丁、Caddy 和辅助 Mihomo 从腾讯云迁至 NoSLA；冻结快照及 34 张表、35 个绑定资源摘要一致。
- 四条相关 A 记录指向 NoSLA，网页/API 使用 443，旧客户端 8443 保留；公开可信证书与域名专用严格 TLS 生效，访问无需 Vercel。
- 后台 app_url 指向 cloud.bingcn.site，引导池同步 API 与兼容域名，仍由服务端提供配置。
- 配置交换空间、资源和队列上限及代理回环监听；512MiB 初始 OOM 经调整重建修复，1GB 主机尚未完成生产容量验收。
- 公网 24 项、公网证书和直接源站 TLS 各 8 项、两入口真实订阅读取和浏览器注册页验证通过；未提交注册或交易。旧业务容器停止，回滚数据保留。详情见 SERVER_DEPLOYMENT.md。

## [Unreleased] - 邀请返利客户端 (2026-09-22)

- 账户页增加邀请返利入口，可读取并主动创建邀请码，复制网站注册链接与邀请码，显示邀请注册二维码。
- 展示 Xboard 注册人数、累计佣金、确认中佣金与可用佣金；币种由服务端提供，返利计算与结算保持在后台。
- 分享网站不可用时降级为邀请码；异常统计响应不展示为零；登录状态变化使页面数据失效。
- 补充七种语言资源以及邀请模型、接口、页面交互测试。
- 建立共享业务主线与独立平台验收路线；iOS 需要 Packet Tunnel/IAP，已有 iPhone，开发者团队待准备。
- 测试面板的网站地址配置为 `https://cloud.microsoftnexushub.top:8443`；App 实际读取配置、生成邀请链接与网页预填已验证，配置旧值已备份。
- 在测试面板精确镜像的无网络、只读临时容器中，通过真实 HTTP Kernel/业务服务/结算命令验证邀请归属与返佣；使用内存业务库和模拟付款完成状态，未产生真实交易。公网注册提交、下载引导、支付及并发结算仍需独立验收。
- 桌面收银使用系统浏览器，Android 控制器在重绘时复用，初始收银地址只接受 HTTPS；增加失败反馈及平台回归测试。
- 补齐 macOS Keychain entitlement，将 Podfile 与 Xcode 最低系统版本对齐当前 Xcode 27 SDK 的 macOS 12 要求，并更新 Pod 锁文件。
- 增加非发布的桌面构建验证脚本、Windows GitHub 标准 Runner 工作流与 PDEC；保留既有发版入口。
- 修复 Windows 首次 Flutter 初始化日志、批处理入口与短路径盘符根目录兼容问题，补齐 SQLite 等原生资产的安装目录复制，并固定 Flutter 平台生成文件为 LF 换行。
- macOS arm64 和 Windows x64 原生编译通过，分别保留 127/82 个包内文件的哈希清单；Windows 开发产物上传至 CI。正式签名、安装分发与 VPN 实机验收仍需完成。

## [Unreleased] - feature/m1-account-subscription (2026-09-08)

### 新增特性 (Features)
- **Xboard 商业版账号与订阅闭环**：
  - 支持内嵌式登录、注册、密码找回流程与 Auth Token 安全持久化（`SecureStore`）。
  - 支持套餐订阅信息自动同步与到期/流量监测。
  - 支持应用内商品列表（`Store`）、下单购买与历史订单查询。
- **高可用域名自动切换与救援**：
  - 引入 `DomainScheduler` 域名池健康探测与无感连接层故障轮换机制。
  - 支持远端引导源（`BootstrapClient`）更新入口域名池。
  - 支持订阅 Profile URL 主机名（Host/Port）热替换。
- **节点商业脱敏与地域智能包装**：
  - 实现 `NodePackager`：自动将节点清洗归入所属国家/地区分组。
  - 支持组内会话保持负载均衡 (`load-balance` with `sticky-sessions`) 或自动优选 (`url-test`)。
  - 首页支持商业版精简地域卡片与延时挡位聚合显示。
- **多语言适配**：
  - 补充 `en`, `zh_CN`, `zh_TC`, `ja`, `ko`, `ru`, `fa` 七种语言关于账号、订阅、订单及地域命名的国际化资源。

---

## [1.19.0+2026081601] - 2026-08-16
- 基于 Mihomo (Clash Meta) 内核的基础开源版。
- 多平台网络调试及规则分流客户端，支持 Android、macOS、Windows、Linux。
- 提供可视化设置、Widget 小组件、自定义主题与分流 UI 适配。

Android 原生启停接线：Go State/CallbackGate/FDLease、Kotlin 显式领取租约及 JNI Boolean 已接入；输入关闭失败阻断新启动，protect 失败传回 socket 创建方。实际 ARM64 Go 核心及生产 JNI 编译链接通过，纯 Go race 与 Kotlin 租约6例通过，独立静态审阅未发现新增 P1/P2。完整 Service 代际保护、有效 NativeTun 构造和设备启动/停止行为尚待验收，不能将该编译产物作为可用发行版。回执为 `docs/validation/2026-10-07-three-platform/android-tun-abi-validation.json`。

Android 生命周期候选接入完整工作门禁、独立绑定/启动意图及主进程停止锁恢复；旧通知无法修改新代共享状态。两个生产gate/controller协程夹具入口通过，原4项独立审阅发现静态闭合；JNI helper/OnLoad九项故障夹具通过。完整工程及设备行为待验，回执分别为 `android-vpn-lifecycle-validation.json`、`android-jni-failure-validation.json`（位于 `docs/validation/2026-10-07-three-platform/`）。

- macOS Application按代次分别确认内核初始化与配置就绪，代理偏好兑现失败后同值会真实重试；停止和退出先确认代理恢复及所属入口撤销。219项Flutter测试、静态分析和完整unsigned Release构建通过；TUN旧提权入口已删除，真实系统授权和流量仍待验证。

- macOS系统代理采用原生Authorization Services默认权限参数及同步资源生命周期，明确取消保持cancelled，已撤销请求在授权前拒绝，运行双读后撤销禁止提交；关闭不确定结果阻断虚假恢复。76项基线测试先确认3处失败，修复后84项通过，SDK宿主和完整unsigned Runner构建通过；真实OS认证和代理流量未验收。

### Android TUN 配置预留模块（2026-10-08）

- 增加配置版本预留、同次 options 复制、启动/停止报告核验与未知责任保留。
- 六项模块回归、完整 core CGO0 测试和 Android ARM64 核心编译通过；core race 因离线 CGO 依赖缺失未启动。真实 TUN/JNI 接线和新 APK 尚未验收。

Android 原生配置回执解析器支持 `tunConfigurationReserved` 与 `tunCleanupUnknown`，并验证相应拒绝/未知状态和版本组合。旧解析器红回归失败、修复后夹具通过；实际设备与 owner 接线另验。

### Android 拒绝输入清理（2026-10-08）

- 新增独立拒绝输入收尾入口，保留旧连接，避免复用启动流程时误停旧资源。
- 四项测试（含四种失败子场景）、并发拒绝输入及完整 androidstartup race 通过；真实入口接线与 APK 另验。

### Android VPN/非VPN模式核验（2026-10-08）

修复配置预留误拒合法fd0非VPN启动，并按预留快照拒绝双向模式不匹配。八项定向、全core CGO0与Android ARM64核心编译通过；实际JNI接线和APK另验。

### Android资源身份（2026-10-08）

增加State资源完整身份与匹配停止，阻止迟到旧代stop及无身份旁路停止新受管资源。十项回归、完整startup race和Android ARM64核心编译通过；真实JNI/owner及APK尚未接线验收。

### Android输入处置事实（2026-10-08）

- 增加Go回调租约的原子完成状态及Kotlin FD领取快照，修复重复Once调用洗白已知释放失败及关闭回调重入提前确认。
- Go三项及完整startup race、Kotlin六组与两个重入子场景、Android ARM64核心编译通过。实际JNI/owner与APK另验。

## [Unreleased] - JNI领取前异常收尾 (2026-10-08)

JNI实际启动入口对领取前global ref删除检查并清除异常，失败保存库生命周期cleanup unknown；Java claim异常同样保存移交未知。未知责任阻断后续启动，stop仍尝试Go资源回收但不得报告整体成功。六项公开函数表ASAN场景修复前有三项失败，修复后全部通过；既有17项释放、9项故障回归及NDK28/API26 ARM64生产JNI链接通过。该证据不覆盖真实JVM/CheckJNI、并发准入、typed owner或新APK。

## [Unreleased] - Android Go带身份启停入口 (2026-10-08)

Android Go新增带epoch/configRevision/generation的startTUNOwned/stopTUNOwned C导出。生产桥在配置锁内预留并复制构造值，锁外调用State和实际NativeTun，最后锁内核验；拒绝输入从同次State报告捕获旧资源身份，stop须同时匹配reservation与State。准备异常、输入/关闭未知保留阻断，fd0仅在非VPN模式采用。九项桥接测试含两项单侧身份漂移、全core CGO0、startup race、NDK28/API26 ARM64 c-shared及同次JNI链接通过，ELF包含两个导出符号。JNI/Kotlin调用方、旧FFI/HTTP/quickStart配置和启停旁路尚未采用/收敛，不能将该ABI候选称为完整客户端或设备验收。

## [Unreleased] - 带身份TUN的JNI与Core回执通路 (2026-10-08)

Android新增startOwnedTunNative/stopOwnedTunNative JNI入口，传递epoch/configRevision/generation至Go；领取前失败收尾检查引用删除，普通负claim调用空负输入取得Go报告，Java领取异常或JNI清理未知不进入新启动。Go C堆回执始终在Java字符串转换后释放，stop先尝试Go按身份收尾，JNI未知时返回null。Core新增Raw调用，OwnedTunInvocation在finally关闭未领FD之后捕获不可变输入快照，异常/null/关闭失败粘滞阻断。九项生产JNI函数表ASAN、六项Invocation JVM行为、完整Core/TunInterface对公开Android SDK jar编译、旧17+6+9项JNI回归和NDK同次头链接通过。该验证未执行Core/ParcelFileDescriptor的实际运行；严格owner解析、VpnPlugin采用、并发事务及旧旁路收敛仍未完成，不能声明新入口已启用或发行包可用。

## [Unreleased] - Kotlin TUN回执与最终完成核验 (2026-10-08)

Android NativeTunProtocol严格解析Go固定十四字段及大小写敏感的资源身份，校验request/operation、outcome/phase、配置代次、资源快照与VPN模式；拒绝重复键、尾随值、非规范整数、溢出、非法Unicode/转义及错误类型。NativeTunCompletion在Core finally后核验输入处置：Go成功start必须与CLAIMED一致；本地未确认、bridgeBlocked、null或协议错误统一unknown+blocked，保留已成功解析的原生责任。可编译占位契约RED失败、生产解析和最终完成夹具GREEN通过；真实Go生产桥生成九种公开回执后由Kotlin直接消费，通过既有配置parser回归及独立审阅。解析器仍用全局错误码白名单，未按操作分区；实际唯一owner/VpnPlugin采用、真实FD/CheckJNI及新APK另验。
