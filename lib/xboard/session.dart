/// 会话状态（非 codegen Riverpod，与上游 codegen 风格隔离）。
///
/// 启动时从安全存储恢复凭据并经 `user/checkLogin` 校验；401 触发静默登出（F-AUTH-4）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'domain_manager.dart';
import 'models.dart';
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
  });

  final SessionStatus status;
  final String? authData;
  final String? email;
  final XboardUserInfo? userInfo;
  final XboardSubscribeInfo? subscribeInfo;

  XboardSessionState copyWith({
    SessionStatus? status,
    String? authData,
    String? email,
    XboardUserInfo? userInfo,
    XboardSubscribeInfo? subscribeInfo,
    bool clearSubscribe = false,
  }) {
    return XboardSessionState(
      status: status ?? this.status,
      authData: authData ?? this.authData,
      email: email ?? this.email,
      userInfo: userInfo ?? this.userInfo,
      subscribeInfo: clearSubscribe ? null : (subscribeInfo ?? this.subscribeInfo),
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
      if (error.isAuth) {
        ref.read(xboardAuthDataProvider.notifier).state = null;
        ref.read(xboardSessionProvider.notifier).onAuthRejected();
      }
    },
  );
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
    state = state.copyWith(userInfo: info);
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
  }

  Future<void> _logoutLocal() async {
    ref.read(xboardAuthDataProvider.notifier).state = null;
    await _store.clearSession();
    state = XboardSessionState(status: SessionStatus.unauthenticated);
  }
}

final xboardSessionProvider =
    NotifierProvider<XboardSessionNotifier, XboardSessionState>(
  XboardSessionNotifier.new,
);
