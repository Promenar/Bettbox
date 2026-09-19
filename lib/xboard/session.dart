/// 会话状态（非 codegen Riverpod，与上游 codegen 风格隔离）。
///
/// 启动时从安全存储恢复凭据并经 `user/checkLogin` 校验；401 触发静默登出（F-AUTH-4）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'binding.dart';
import 'bootstrap.dart';
import 'domain_manager.dart';
import 'domain_scheduler.dart';
import 'models.dart';
import 'region_catalog.dart';
import 'repositories.dart';
import 'secure_store.dart';

enum SessionStatus { restoring, authenticated, unauthenticated }

class XboardSessionState {
  const XboardSessionState({
    this.status = SessionStatus.restoring,
    this.authData,
    this.email,
    this.userInfo,
    this.subscribeInfo,
    this.refreshedAt,
  });

  final SessionStatus status;
  final String? authData;
  final String? email;
  final XboardUserInfo? userInfo;
  final XboardSubscribeInfo? subscribeInfo;

  /// 面板数据最近成功刷新时间（订阅卡“数据更新于”展示依据）。
  final DateTime? refreshedAt;

  XboardSessionState copyWith({
    SessionStatus? status,
    String? authData,
    String? email,
    XboardUserInfo? userInfo,
    XboardSubscribeInfo? subscribeInfo,
    DateTime? refreshedAt,
    bool clearSubscribe = false,
  }) {
    return XboardSessionState(
      status: status ?? this.status,
      authData: authData ?? this.authData,
      email: email ?? this.email,
      userInfo: userInfo ?? this.userInfo,
      subscribeInfo: clearSubscribe ? null : (subscribeInfo ?? this.subscribeInfo),
      refreshedAt: refreshedAt ?? this.refreshedAt,
    );
  }

  bool get isAuthenticated => status == SessionStatus.authenticated;
}

final xboardDomainManagerProvider = Provider<XboardDomainManager>(
  (ref) => XboardDomainManager(),
);

final xboardSecureStoreProvider = Provider<XboardSecureStore>(
  (ref) => XboardSecureStore(),
);

/// 当前 Bearer 凭据（与 session 状态解耦，避免 apiClient↔session 循环依赖）。
final xboardAuthDataProvider = StateProvider<String?>((ref) => null);

final xboardApiClientProvider = Provider<XboardApiClient>((ref) {
  return XboardApiClient(
    domainManager: ref.watch(xboardDomainManagerProvider),
    authDataProvider: () => ref.read(xboardAuthDataProvider),
    onError: (error) {
      // 仅 401 判定凭据失效；Xboard 用 403 表达订阅域业务拒绝（如套餐过期），
      // 不应触发静默登出。
      if (error.type == XboardErrorType.auth &&
          error.statusCode == 401) {
        ref.read(xboardAuthDataProvider.notifier).state = null;
        ref.read(xboardSessionProvider.notifier).onAuthRejected();
      }
    },
  );
});

final xboardBootstrapClientProvider = Provider<XboardBootstrapClient>(
  (ref) => XboardBootstrapClient(),
);

final xboardDomainSchedulerProvider = Provider<XboardDomainScheduler>((ref) {
  final manager = ref.watch(xboardDomainManagerProvider);
  final scheduler = XboardDomainScheduler(
    domainManager: manager,
    secureStore: ref.read(xboardSecureStoreProvider),
    bootstrapClient: ref.read(xboardBootstrapClientProvider),
    apiClient: ref.read(xboardApiClientProvider),
    callbacks: XboardDomainCallbacks(
      onPoolChanged: (domains) {
        ref.read(xboardDomainStateProvider.notifier).state = XboardDomainState.of(
          manager,
        );
      },
      onActiveChanged: (baseUrl) async {
        ref.read(xboardDomainStateProvider.notifier).state = XboardDomainState.of(
          manager,
        );
        // 未登录态冻结订阅更新（登出后仅保活不断连，重登后全量同步）
        if (!ref.read(xboardSessionProvider).isAuthenticated) return;
        // F-DOMAIN-5：订阅 URL host 热替换 + 刷新（失败保留原订阅，下次触发再试；
        // 异常仅日志，不向 UI 抛，避免无订阅账号刷屏）。
        try {
          await applyManagedDomainHost(baseUrl);
          await refreshManagedSubscription();
        } catch (error) {
          debugPrint('[XBOARD_DOMAIN] post-switch sync skipped: $error');
        }
      },
      onCatalogChanged: (catalog) {
        ref.read(xboardRegionCatalogProvider.notifier).state = catalog;
      },
      onAnnouncementChanged: (url) {
        ref.read(xboardAnnouncementUrlProvider.notifier).state = url;
      },
    ),
  );
  return scheduler;
});

final xboardAuthRepositoryProvider = Provider<XboardAuthRepository>(
  (ref) => XboardAuthRepository(ref.watch(xboardApiClientProvider)),
);

final xboardUserRepositoryProvider = Provider<XboardUserRepository>(
  (ref) => XboardUserRepository(ref.watch(xboardApiClientProvider)),
);

final xboardGuestRepositoryProvider = Provider<XboardGuestRepository>(
  (ref) => XboardGuestRepository(ref.watch(xboardApiClientProvider)),
);

final xboardOrderRepositoryProvider = Provider<XboardOrderRepository>(
  (ref) => XboardOrderRepository(ref.watch(xboardApiClientProvider)),
);

/// 地域目录（F-NODE-7 通道② 引导源静态字段；通道①就绪后同模型复用）。
final xboardRegionCatalogProvider = StateProvider<XboardRegionCatalog>(
  (ref) => const XboardRegionCatalog([]),
);

final xboardAnnouncementUrlProvider = StateProvider<String?>((ref) => null);

/// 分流均衡开关（F-NODE-4）：默认开启，持久化值在启动时覆盖。
final xboardLoadBalanceProvider = StateProvider<bool>((ref) => true);

class XboardSessionNotifier extends Notifier<XboardSessionState> {
  @override
  XboardSessionState build() => const XboardSessionState();

  XboardSecureStore get _store => ref.read(xboardSecureStoreProvider);
  XboardUserRepository get _userRepo => ref.read(xboardUserRepositoryProvider);

  /// 启动恢复：安全存储有凭据 → checkLogin 校验；失效则静默清空。
  Future<void> restore() async {
    final saved = await _store.readSession();
    if (saved == null) {
      state = state.copyWith(status: SessionStatus.unauthenticated);
      return;
    }
    ref.read(xboardAuthDataProvider.notifier).state = saved.authData;
    state = state.copyWith(
      status: SessionStatus.authenticated,
      authData: saved.authData,
      email: saved.email,
    );
    try {
      await _userRepo.checkLogin();
      await refreshUserInfo();
      // 登录态恢复自更新能力（登出期间被冻结的受管 Profile）
      await setManagedAutoUpdate(true);
    } on XboardException catch (error) {
      if (error.isAuth) {
        await _logoutLocal();
      } else {
        // 网络/服务异常：保留本地会话，进入离线可用态。
      }
    }
  }

  Future<void> login({required String email, required String password}) async {
    final result = await ref.read(xboardAuthRepositoryProvider).login(
          email: email,
          password: password,
        );
    await _adoptAuthResult(result, email);
  }

  Future<void> register({
    required String email,
    required String password,
    required String emailCode,
    String? inviteCode,
  }) async {
    final result = await ref.read(xboardAuthRepositoryProvider).register(
          email: email,
          password: password,
          emailCode: emailCode,
          inviteCode: inviteCode,
        );
    await _adoptAuthResult(result, email);
  }

  Future<void> sendEmailVerify(String email) async {
    await ref.read(xboardAuthRepositoryProvider).sendEmailVerify(email);
  }

  Future<void> refreshUserInfo() async {
    final info = await _userRepo.info();
    state = state.copyWith(userInfo: info, refreshedAt: DateTime.now());
    try {
      final subscribe = await _userRepo.getSubscribe();
      state = state.copyWith(subscribeInfo: subscribe);
    } on XboardException catch (error) {
      if (error.isBusiness) {
        // 无套餐边界（Q4）：订阅信息置空，UI 呈现开通引导态。
        state = state.copyWith(clearSubscribe: true);
      } else {
        rethrow;
      }
    }
  }

  DateTime? _lastCycle;

  /// SaaS 级订阅自更新：面板数据（流量/套餐/更新时间）+ 订阅内容（节点）一次拉齐。
  ///
  /// 未登录直接返回（登出态冻结）；默认 2 分钟节流，前台 6h 定时器可用
  /// force 绕过。离线等异常由调用方决定是否提示，订阅卡场景静默保底。
  Future<void> refreshSubscriptionCycle({bool force = false}) async {
    if (!state.isAuthenticated) return;
    final now = DateTime.now();
    if (!force &&
        _lastCycle != null &&
        now.difference(_lastCycle!) < const Duration(minutes: 2)) {
      return;
    }
    _lastCycle = now;
    await refreshUserInfo();
    await refreshManagedSubscription();
  }

  Future<void> logout() async {
    // 仅本地登出；服务端 Sanctum token 无主动吊销端点，一年后自然过期。
    await _logoutLocal();
  }

  /// 401/403 时的静默登出（不清除已下载订阅等本地数据）。
  void onAuthRejected() {
    _logoutLocal();
  }

  Future<void> _adoptAuthResult(XboardAuthResult result, String email) async {
    ref.read(xboardAuthDataProvider.notifier).state = result.authData;
    await _store.saveSession(authData: result.authData, email: email);
    state = XboardSessionState(
      status: SessionStatus.authenticated,
      authData: result.authData,
      email: email,
    );
    await refreshUserInfo();
    await setManagedAutoUpdate(true);
  }

  Future<void> _logoutLocal() async {
    ref.read(xboardAuthDataProvider.notifier).state = null;
    await _store.clearSession();
    state = XboardSessionState(status: SessionStatus.unauthenticated);
    // 登出冻结：配置保留可用，但不再自更新订阅内容与面板数据
    await setManagedAutoUpdate(false);
  }
}

final xboardSessionProvider =
    NotifierProvider<XboardSessionNotifier, XboardSessionState>(
  XboardSessionNotifier.new,
);
