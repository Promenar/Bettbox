import 'dart:async';
import 'supervisor_codec.dart';
import 'supervisor_readiness.dart';
import 'supervisor_rpc.dart';
import 'supervisor_session.dart';
import 'supervisor_events.dart';

typedef SupervisorSessionBuilder =
    SupervisorSession Function(
      void Function(Object?) result,
      void Function() revoked,
    );

// 应用生命周期协调器只使用Session停止证据，不将状态布尔值授权给SC。
class SupervisorApplication {
  SupervisorApplication({required this.buildSession, required this.onEvent});
  final SupervisorSessionBuilder buildSession;
  final SupervisorEventBatch Function(Map<String, Object?>) onEvent;
  SupervisorSession? _session;
  SupervisorRpc? _rpc;
  Future<void>? _initial;
  Future<void>? _tail;
  int _intent = 0;
  int _generation = 0;
  int _queuedRestarts = 0;
  int _requests = 0;
  bool _destroying = false;

  bool get isReady =>
      !_destroying &&
      _session?.state == SupervisorState.ready &&
      _rpc?.isClosed == false;
  bool get hasUnconfirmedOwner =>
      (_session?.hasUnconfirmedOwner ?? false) ||
      (_rpc?.hasUnconfirmedConsumers ?? false);
  int get generation => _generation;
  int get requestCount => _requests;

  Future<void> initialize() {
    final initial = _initial ??= restart();
    unawaited(initial.then<void>((_) {}, onError: (Object _) {}));
    return initial;
  }

  Future<bool> preload() => awaitSupervisorReady(
    initial: _initial,
    pending: () => _tail,
    ready: () => isReady,
  );

  Future<void> restart() async {
    if (_queuedRestarts >= 8) throw const SupervisorFailure('重启请求已满');
    _queuedRestarts++;
    final intent = ++_intent;
    _destroying = false;
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    try {
      await previous;
      _active(intent);
      if (!await _stopCurrent()) throw const SupervisorFailure('旧会话停止尚未确认');
      _active(intent);
      late final SupervisorRpc rpc;
      final session = buildSession(
        (value) => rpc.receive(value),
        () => rpc.close(),
      );
      rpc = SupervisorRpc(
        generation: ++_generation,
        send: (id, method, data) =>
            session.sendAction(id: id, method: method, data: data),
        onFatal: () {
          unawaited(session.stop());
        },
        onEvent: onEvent,
      );
      _session = session;
      _rpc = rpc;
      await session.start(_generation);
      if (intent != _intent || _destroying) {
        await _stopCurrent();
        throw const SupervisorFailure('会话启动已撤销');
      }
    } finally {
      _queuedRestarts--;
      if (identical(_tail, completed.future)) _tail = null;
      completed.complete();
    }
  }

  void _active(int intent) {
    if (intent != _intent || _destroying) {
      throw const SupervisorFailure('会话启动已撤销');
    }
  }

  Future<bool> _stopCurrent() async {
    final session = _session;
    _rpc?.close();
    if (session == null) return true;
    final stopped = await session.stop();
    if (!stopped || session.hasUnconfirmedOwner) return false;
    if (_rpc?.hasUnconfirmedConsumers == true) return false;
    if (identical(_session, session)) {
      _session = null;
      _rpc = null;
    }
    return true;
  }

  Future<bool> shutdown() async {
    final intent = ++_intent;
    _destroying = true;
    final pending = _tail;
    final stopped = await _stopCurrent();
    await pending;
    if (intent != _intent) return false;
    return await _stopCurrent() && stopped;
  }

  Future<Map<String, dynamic>> request({
    required String method,
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // 就绪等待也占准入预算，不能在启动阶段形成无限Future积压。
    if (_requests >= SupervisorRpc.pendingLimit) {
      throw const SupervisorFailure('在途请求已满');
    }
    _requests++;
    try {
      if (!await preload()) throw const SupervisorFailure('macOS内核会话未就绪');
      return await _rpc!.request(method: method, data: data, timeout: timeout);
    } finally {
      _requests--;
    }
  }
}
