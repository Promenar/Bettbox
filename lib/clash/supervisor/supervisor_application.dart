import 'dart:async';
import 'supervisor_codec.dart';
import 'supervisor_readiness.dart';
import 'supervisor_rpc.dart';
import 'supervisor_session.dart';
import 'supervisor_events.dart';
import 'supervisor_system_proxy.dart';

typedef SupervisorSessionBuilder =
    SupervisorSession Function(
      void Function(Object?) result,
      void Function() revoked,
    );

class _LifecycleWork {
  _LifecycleWork(this.run, this.cancel, this.stopping);
  final Future<void> Function() run;
  final void Function() cancel;
  final bool stopping;
  final drained = Completer<void>();
}

// 应用资源由同一有界队列串行协调；用户偏好不等于实际生效证据。
class SupervisorApplication {
  SupervisorApplication({
    required this.buildSession,
    required this.onEvent,
    this.onRuntimeChanged,
  });
  final SupervisorSessionBuilder buildSession;
  final SupervisorEventBatch Function(Map<String, Object?>) onEvent;
  final void Function(DateTime?)? onRuntimeChanged;
  SupervisorSession? _session;
  SupervisorRpc? _rpc;
  Future<void>? _initial;
  Future<void>? _tail;
  Future<bool>? _shutdownFuture;
  Future<bool>? _preferenceFuture;
  Future<bool>? _runtimeStopFuture;
  final _pending = <_LifecycleWork>[];
  bool _draining = false;
  int _intent = 0;
  int _runtimeIntent = 0;
  int _generation = 0;
  int _queued = 0;
  int _requests = 0;
  bool _destroying = false;
  bool _runtimeWanted = false;
  bool _initialized = false;
  bool _configured = false;
  bool _proxyEnabled = false;
  bool _preferenceConfirmed = true;
  List<String> _bypass = const [];
  OwnedHttpEndpoint? _endpoint;
  bool _endpointMayExist = false;
  bool _runtimeConfirmed = false;
  DateTime? _startedAt;

  bool get isReady =>
      !_destroying &&
      _session?.state == SupervisorState.ready &&
      _rpc?.isClosed == false;
  bool get hasUnconfirmedOwner =>
      _endpointMayExist ||
      _endpoint != null ||
      (_session?.hasUnconfirmedOwner ?? false) ||
      (_rpc?.hasUnconfirmedConsumers ?? false);
  int get generation => _generation;
  int get requestCount => _requests;
  DateTime? get startedAt => _startedAt;
  bool get isRuntimeActive =>
      _runtimeConfirmed && _endpoint != null && _startedAt != null && isReady;

  Future<T> _enqueue<T>(
    Future<T> Function() operation, {
    bool stopping = false,
  }) {
    if (_queued >= 8) return Future.error(const SupervisorFailure('生命周期请求已满'));
    _queued++;
    final result = Completer<T>();
    final work = _LifecycleWork(
      () async {
        try {
          result.complete(await operation());
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
      () {
        result.completeError(const SupervisorFailure('生命周期请求已撤销'));
      },
      stopping,
    );
    _pending.add(work);
    _tail = work.drained.future;
    if (!_draining) unawaited(_drain());
    return result.future;
  }

  Future<void> _drain() async {
    _draining = true;
    while (_pending.isNotEmpty) {
      final work = _pending.removeAt(0);
      await work.run();
      _queued--;
      if (identical(_tail, work.drained.future)) _tail = null;
      work.drained.complete();
    }
    _draining = false;
  }

  void _cancelPending({bool keepStop = false}) {
    final cancelled = _pending
        .where((work) => !keepStop || !work.stopping)
        .toList();
    for (final work in cancelled) {
      work.cancel();
      work.drained.complete();
      _queued--;
      _pending.remove(work);
    }
  }

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

  Future<void> restart() {
    if (_shutdownFuture != null) {
      return Future.error(const SupervisorFailure('退出处理中'));
    }
    if (_queued >= 8) return Future.error(const SupervisorFailure('生命周期请求已满'));
    final intent = ++_intent;
    ++_runtimeIntent;
    _destroying = false;
    return _enqueue(() async {
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
          ++_runtimeIntent;
          _runtimeConfirmed = false;
          // 已坏RPC不能伪造ownedStop；Session独立恢复并保留出生核对责任。
          unawaited(session.stop());
        },
        onEvent: onEvent,
      );
      _session = session;
      _rpc = rpc;
      _initialized = false;
      _configured = false;
      await session.start(_generation);
      if (intent != _intent || _destroying) {
        await _stopCurrent();
        throw const SupervisorFailure('会话启动已撤销');
      }
    });
  }

  void _active(int intent) {
    if (intent != _intent || _destroying) {
      throw const SupervisorFailure('会话启动已撤销');
    }
  }

  void _runtimeChanged(DateTime? value) {
    _startedAt = value;
    try {
      onRuntimeChanged?.call(value);
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _raw(
    String method,
    Object? data, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final rpc = _rpc;
    if (rpc == null ||
        rpc.isClosed ||
        _session?.state != SupervisorState.ready) {
      throw const SupervisorFailure('内核请求通道不可用');
    }
    return rpc.request(method: method, data: data, timeout: timeout);
  }

  bool _runtimeCurrent(int intent) =>
      intent == _runtimeIntent && _runtimeWanted && !_destroying && isReady;

  Future<bool> _startRuntime(int intent) async {
    // 握手和init不能证明本代配置存在；冷update空串也不能提升就绪。
    if (!_runtimeCurrent(intent) || !_initialized || !_configured) return false;
    try {
      final started = await _startRuntimeChecked(intent);
      if (intent == _runtimeIntent) _preferenceConfirmed = started;
      return started;
    } catch (_) {
      if (intent == _runtimeIntent) _preferenceConfirmed = false;
      _runtimeConfirmed = false;
      // 无法识别入口身份时不能伪造ownedStop，转独立出生确认。
      if (_endpoint == null && _endpointMayExist) {
        if (!await _session!.recoverSystemProxy()) {
          throw const SupervisorFailure('系统代理恢复尚未确认');
        }
        _rpc?.close();
      }
      if (!await _releaseEndpoint()) {
        throw const SupervisorFailure('系统代理恢复尚未确认');
      }
      return false;
    }
  }

  Future<bool> _startRuntimeChecked(int intent) async {
    if (_endpoint == null) {
      _endpointMayExist = true;
      final reply = await _raw('ownedHttpStart', const <String, Object>{});
      if (reply['code'] != 0) throw const SupervisorFailure('专用入口未确认');
      _endpoint = OwnedHttpEndpoint.fromReply(
        reply['data'],
        generation: _generation,
      );
    }
    if (!_runtimeCurrent(intent)) {
      await _releaseEndpoint();
      return false;
    }
    if (_proxyEnabled) {
      _runtimeConfirmed = false;
      final result = await _session!.activateSystemProxy(_endpoint!, _bypass);
      if (!_runtimeCurrent(intent)) {
        await _releaseEndpoint();
        return false;
      }
      if (result.status != SystemProxyStatus.applied ||
          result.unresolvedGroups != 0) {
        if (!await _releaseEndpoint()) {
          throw const SupervisorFailure('系统代理恢复尚未确认');
        }
        return false;
      }
    }
    _runtimeConfirmed = true;
    _runtimeChanged(_startedAt ?? DateTime.now());
    return true;
  }

  Future<bool> startRuntime() {
    if (_destroying) return Future.value(false);
    if (_queued >= 8) return Future.error(const SupervisorFailure('生命周期请求已满'));
    _runtimeWanted = true;
    final intent = ++_runtimeIntent;
    return _enqueue(() => _startRuntime(intent));
  }

  Future<bool> stopRuntime() {
    _runtimeWanted = false;
    ++_runtimeIntent;
    if (_runtimeStopFuture != null) {
      _cancelPending(keepStop: true);
      return _runtimeStopFuture!;
    }
    _cancelPending();
    final stopped = _enqueue(_releaseEndpoint, stopping: true);
    _runtimeStopFuture = stopped;
    unawaited(
      stopped.then<void>(
        (_) {
          if (identical(_runtimeStopFuture, stopped)) _runtimeStopFuture = null;
        },
        onError: (Object _) {
          if (identical(_runtimeStopFuture, stopped)) _runtimeStopFuture = null;
        },
      ),
    );
    return stopped;
  }

  Future<bool> setSystemProxyPreference({
    required bool enabled,
    required List<String> bypass,
  }) {
    if (_destroying) return Future.value(false);
    final sameBypass =
        bypass.length == _bypass.length &&
        List.generate(
          bypass.length,
          (index) => index,
        ).every((index) => bypass[index] == _bypass[index]);
    if (enabled == _proxyEnabled && sameBypass) {
      final pending = _preferenceFuture;
      if (pending != null) return pending;
      if (_preferenceConfirmed) return Future.value(true);
    }
    if (_queued >= 8) return Future.error(const SupervisorFailure('生命周期请求已满'));
    _proxyEnabled = enabled;
    _bypass = List<String>.unmodifiable(bypass);
    _preferenceConfirmed = false;
    final intent = ++_runtimeIntent;
    final preference = _enqueue(() async {
      if (intent != _runtimeIntent || _destroying) return false;
      if (!_runtimeWanted || !_initialized || !_configured) {
        // 仅采纳供后续运行兑现的偏好，不声称系统代理已生效。
        _preferenceConfirmed = true;
        return true;
      }
      // Host将bypass绑定于入口epoch；任何偏好变化均释放旧入口后重建。
      if (_endpoint != null && !await _releaseEndpoint()) return false;
      final started = await _startRuntime(intent);
      if (started && intent == _runtimeIntent && !_destroying) {
        _preferenceConfirmed = true;
      }
      return started;
    });
    _preferenceFuture = preference;
    unawaited(
      preference.then<void>(
        (_) {
          if (identical(_preferenceFuture, preference)) {
            _preferenceFuture = null;
          }
        },
        onError: (Object _) {
          if (identical(_preferenceFuture, preference)) {
            _preferenceFuture = null;
          }
        },
      ),
    );
    return preference;
  }

  // 不依赖存活proof；正常RPC必须确认精确ownedStop，故障RPC只走出生确认。
  Future<bool> _releaseEndpoint() async {
    try {
      return await _releaseEndpointChecked();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _releaseEndpointChecked() async {
    final session = _session;
    if (session == null) return !_endpointMayExist && _endpoint == null;
    if (!await session.recoverSystemProxy()) return false;
    final endpoint = _endpoint;
    if (endpoint == null && _endpointMayExist) _rpc?.close();
    if (_rpc?.isClosed == true || session.state != SupervisorState.ready) {
      if (!await session.stop() || session.hasUnconfirmedOwner) return false;
      _endpoint = null;
      _endpointMayExist = false;
      _runtimeConfirmed = false;
      _runtimeChanged(null);
      return true;
    }
    if (endpoint != null) {
      _runtimeConfirmed = false;
      final reply = await _raw('ownedHttpStop', const <String, Object>{});
      final data = reply['data'];
      if (reply['code'] != 0 ||
          data is! Map ||
          data.length != 3 ||
          !data.keys.every({'generation', 'listenerEpoch', 'state'}.contains) ||
          data['generation'] is! int ||
          data['generation'] != endpoint.generation ||
          data['listenerEpoch'] is! int ||
          data['listenerEpoch'] != endpoint.listenerEpoch ||
          data['state'] != 'stopped') {
        return false;
      }
      _endpoint = null;
      _endpointMayExist = false;
      _runtimeConfirmed = false;
      _runtimeChanged(null);
    }
    if (_endpointMayExist) return false;
    return true;
  }

  Future<bool> _stopCurrent() async {
    final session = _session;
    if (!await _releaseEndpoint()) return false;
    if (session == null) return true;
    _rpc?.close();
    if (!await session.stop() ||
        session.hasUnconfirmedOwner ||
        _rpc?.hasUnconfirmedConsumers == true) {
      return false;
    }
    if (identical(_session, session)) {
      _session = null;
      _rpc = null;
      _initialized = false;
      _configured = false;
    }
    return true;
  }

  Future<bool> shutdown() {
    if (_shutdownFuture != null) return _shutdownFuture!;
    final intent = ++_intent;
    ++_runtimeIntent;
    _runtimeWanted = false;
    _initialized = false;
    _configured = false;
    _destroying = true;
    // 等待中的旧请求立即终止并释放准入，退出仍在同一执行队列内。
    _cancelPending();
    final shutdown = _enqueue(() async {
      if (intent != _intent) return false;
      _initialized = false;
      _configured = false;
      try {
        final stopped = await _stopCurrent();
        if (!stopped && intent == _intent) _destroying = false;
        return stopped;
      } catch (_) {
        if (intent == _intent) _destroying = false;
        return false;
      }
    });
    _shutdownFuture = shutdown;
    unawaited(
      shutdown.then<void>((_) {
        if (identical(_shutdownFuture, shutdown)) _shutdownFuture = null;
      }),
    );
    return shutdown;
  }

  Future<Map<String, dynamic>> request({
    required String method,
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_requests >= SupervisorRpc.pendingLimit) {
      throw const SupervisorFailure('在途请求已满');
    }
    _requests++;
    try {
      if (const {
        'initClash',
        'setupConfig',
        'updateConfig',
        'shutdown',
      }.contains(method)) {
        return await _enqueue(() async {
          if (_destroying || !await _releaseEndpoint()) {
            throw const SupervisorFailure('系统代理恢复尚未确认');
          }
          final wasConfigured = _configured;
          // RPC异常或错误回包不得保留能够重新构造入口的就绪事实。
          if (method == 'shutdown') _initialized = false;
          _configured = false;
          final reply = await _raw(method, data, timeout: timeout);
          final success =
              reply['code'] == 0 &&
              (method == 'initClash' || method == 'shutdown'
                  ? reply['data'] == true
                  : reply['data'] == '');
          switch (method) {
            case 'initClash':
              _initialized = success;
              _configured = success && wasConfigured;
            case 'setupConfig':
              _configured = success;
            case 'updateConfig':
              _configured = success && wasConfigured;
            case 'shutdown':
              _initialized = false;
              _configured = false;
          }
          if (success &&
              method != 'shutdown' &&
              _initialized &&
              _configured &&
              _runtimeWanted) {
            if (!await _startRuntime(_runtimeIntent)) {
              throw const SupervisorFailure('运行入口未确认');
            }
          }
          return reply;
        });
      }
      if (!await preload()) throw const SupervisorFailure('macOS内核会话未就绪');
      return await _raw(method, data, timeout: timeout);
    } finally {
      _requests--;
    }
  }
}
