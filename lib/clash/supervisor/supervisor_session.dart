import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'supervisor_codec.dart';
import 'supervisor_native.dart';
import 'supervisor_transport.dart';

enum SupervisorState { idle, starting, ready, stopping, stopped, failed }

class _Submission {
  _Submission(this.frame);
  final Uint8List frame;
  final done = Completer<void>();
}

// generation由调用者单调分配，native负责记录出生、身份和撤销状态。
class SupervisorSession {
  SupervisorSession({
    required this.native,
    required this.factory,
    required this.onResult,
    this.startBudget = const Duration(seconds: 5),
    this.stopBudget = const Duration(seconds: 9),
    this.queueLimit = 8,
  }) {
    if (queueLimit < 1 ||
        queueLimit > 8 ||
        startBudget <= Duration.zero ||
        stopBudget <= Duration.zero) {
      throw const SupervisorFailure('会话配置无效');
    }
  }
  final SupervisorNative native;
  final SupervisorTransportFactory factory;
  final FutureOr<void> Function(Object? result) onResult;
  final Duration startBudget;
  final Duration stopBudget;
  final int queueLimit;
  SupervisorState state = SupervisorState.idle;
  String? error;
  int _epoch = 0;
  int _generation = 0;
  int _lastGeneration = 0;
  String? _launch;
  String? _handle;
  SupervisorTransport? _transport;
  Future<int>? _exit;
  bool _exitError = false;
  bool _eof = false;
  Completer<void>? _eofSignal;
  Future<void>? _inputClose;
  bool _helperBindingStarted = false;
  Future<void>? _ledgerFuture;
  int _workers = 0;
  bool _sticky = false;
  bool _revoked = false;
  bool _inputClosed = false;
  Future<bool>? _stopFuture;
  Completer<Map<String, dynamic>>? _stage;
  String? _expected;
  final Queue<_Submission> _queue = Queue<_Submission>();
  _Submission? _active;
  bool _writing = false;
  bool _permit = false;
  int _sequence = 0;
  int? _awaitingCredit;
  bool _creditReceived = false;

  // 未确认退出时保留定位信息和Process，调用者不能用状态字符串授权SC。
  bool get hasUnconfirmedOwner =>
      _transport != null || _handle != null || _workers != 0 || _writing;

  bool _current(int epoch) =>
      epoch == _epoch && state == SupervisorState.starting;
  Duration _remaining(Stopwatch watch, Duration budget) {
    final remaining = budget - watch.elapsed;
    if (remaining <= Duration.zero) throw const SupervisorFailure('会话操作超时');
    return remaining;
  }

  Future<T> _worker<T>(Future<T> future) async {
    _workers++;
    try {
      return await future;
    } finally {
      _workers--;
    }
  }

  Future<T> _bounded<T>(Future<T> future, int epoch, Stopwatch watch) async {
    final value = await future.timeout(_remaining(watch, startBudget));
    _remaining(watch, startBudget);
    if (!_current(epoch)) throw const SupervisorFailure('会话启动已撤销');
    return value;
  }

  Map<String, dynamic> _map(Object? raw, List<String> keys) {
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw protocolFailure;
    }
    final value = Map<String, dynamic>.from(raw);
    exactKeys(value, keys);
    return value;
  }

  void _sameGeneration(Map<String, dynamic> value) {
    if (value['generation'] is! int || value['generation'] != _generation) {
      throw protocolFailure;
    }
  }

  String _opaque(Object? value) {
    if (value is! String || value.isEmpty || value.length > 4096) {
      throw protocolFailure;
    }
    return value;
  }

  Future<void> start(int generation) async {
    if ((state != SupervisorState.idle && state != SupervisorState.stopped) ||
        hasUnconfirmedOwner ||
        generation <= _lastGeneration ||
        generation <= 0 ||
        generation > 0x7fffffffffffffff) {
      throw const SupervisorFailure('旧会话尚未确认停止或代次无效');
    }
    _generation = generation;
    _lastGeneration = generation;
    final epoch = ++_epoch;
    state = SupervisorState.starting;
    _sticky = false;
    _revoked = false;
    _inputClosed = false;
    _eof = false;
    _eofSignal = null;
    _inputClose = null;
    _helperBindingStarted = false;
    _ledgerFuture = null;
    _sequence = 0;
    _awaitingCredit = null;
    _creditReceived = false;
    _exitError = false;
    error = null;
    final initial = Stopwatch()..start();
    try {
      // 迟到reserve只能记录撤销所需launch，不能重新恢复启动权限。
      final reservation =
          _worker(
            native.call('reserveSupervisorLaunch', {'generation': generation}),
          ).then((raw) {
            final value = _map(raw, ['launch', 'generation', 'path']);
            _sameGeneration(value);
            final launch = value['launch'];
            final path = value['path'];
            if (launch is! String ||
                !RegExp(
                  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                ).hasMatch(launch)) {
              throw protocolFailure;
            }
            _launch = launch;
            if (!_current(epoch)) {
              unawaited(
                _revoke().catchError((Object _) {
                  _sticky = true;
                  error ??= '会话撤销失败';
                }),
              );
            }
            if (path is! String ||
                path.length > 4096 ||
                !path.startsWith('/') ||
                path.contains('\u0000') ||
                path.split('/').last != 'BettboxCoreSupervisor') {
              throw protocolFailure;
            }
            return path;
          });
      final path = await _bounded(reservation, epoch, initial);
      final spawned = _worker(factory.spawn(path, generation)).then((
        transport,
      ) {
        _attach(transport);
        if (!_current(epoch)) {
          unawaited(
            _revoke().catchError((Object _) {
              _sticky = true;
              error ??= '会话撤销失败';
            }),
          );
          _recordCanceledHelper();
          _closeInput();
        }
        return transport;
      });
      _expect('supervisor_ready');
      await _bounded(spawned, epoch, initial);
      await _bounded(_stage!.future, epoch, initial);
      _expected = null;
      _helperBindingStarted = true;
      final bound = _map(
        await _bounded(
          _worker(
            native.call('bindSupervisor', {
              'launch': _launch!,
              'generation': generation,
              'pid': _transport!.pid,
            }),
          ),
          epoch,
          initial,
        ),
        ['handle', 'generation'],
      );
      _sameGeneration(bound);
      _handle = _opaque(bound['handle']);

      // prepare之前起算唯一Core预算，core_ready和native worker不会延长它。
      final coreBudget = Stopwatch()..start();
      _expect('core_ready');
      await _bounded(
        _transport!.write(
          encodeSupervisorFrame({
            'type': 'prepare_core',
            'protocol': 1,
            'generation': generation,
            'launch': _launch,
          }, controlFrameLimit),
        ),
        epoch,
        coreBudget,
      );
      final ready = await _bounded(_stage!.future, epoch, coreBudget);
      _expected = null;
      final core = _map(
        await _bounded(
          _worker(
            native.call('bindCoreChain', {
              'handle': _handle!,
              'pid': ready['pid'] as int,
            }),
          ),
          epoch,
          coreBudget,
        ),
        ['handle', 'generation'],
      );
      _sameGeneration(core);
      _handle = _opaque(core['handle']);
      final proof = _map(
        await _bounded(
          _worker(native.call('recheckCoreChain', {'handle': _handle!})),
          epoch,
          coreBudget,
        ),
        ['valid', 'generation'],
      );
      _sameGeneration(proof);
      if (proof['valid'] != true) throw protocolFailure;
      _expect('ack');
      await _bounded(
        _transport!.write(
          encodeSupervisorFrame({
            'type': 'hello',
            'protocol': 1,
            'generation': generation,
          }, controlFrameLimit),
        ),
        epoch,
        coreBudget,
      );
      await _bounded(_stage!.future, epoch, coreBudget);
      _expected = null;
      state = SupervisorState.ready;
      _permit = true;
    } catch (_) {
      _fail('会话启动失败');
      throw const SupervisorFailure('会话启动失败');
    }
  }

  void _expect(String type) {
    _expected = type;
    _stage = Completer<Map<String, dynamic>>();
    // 失败可能先于调用方await，不向Zone泄漏原异常。
    unawaited(_stage!.future.then<void>((_) {}, onError: (Object _) {}));
  }

  void _attach(SupervisorTransport transport) {
    if (_transport != null) throw protocolFailure;
    _transport = transport;
    _eofSignal = Completer<void>();
    _exit = transport.exitCode;
    unawaited(
      _exit!.then<void>(
        (code) {
          if (identical(_transport, transport) &&
              state == SupervisorState.ready) {
            unawaited(stop());
          }
        },
        onError: (Object _) {
          if (identical(_transport, transport)) {
            _exitError = true;
            _fail('监督进程退出观察失败');
          }
        },
      ),
    );
    final reader = SupervisorFrameReader(
      () =>
          state == SupervisorState.ready ||
              state == SupervisorState.stopping ||
              state == SupervisorState.failed
          ? businessFrameLimit
          : controlFrameLimit,
      _frame,
    );
    transport.output.listen(
      (chunk) {
        if (!identical(_transport, transport)) return;
        try {
          reader.add(chunk);
        } catch (_) {
          _fail('控制会话协议校验失败');
        }
      },
      onError: (Object _) {
        if (identical(_transport, transport)) _fail('控制管道读取失败');
      },
      onDone: () {
        if (!identical(_transport, transport)) return;
        try {
          reader.finish();
        } catch (_) {
          _fail('控制帧未完整结束');
          return;
        }
        _eof = true;
        if (!_eofSignal!.isCompleted) _eofSignal!.complete();
        if (state == SupervisorState.starting) {
          _fail('启动控制管道提前关闭');
        } else if (state == SupervisorState.ready) {
          unawaited(stop());
        }
      },
    );
    // 只排空stderr，不解码、不记录payload。
    transport.diagnostics.listen(
      (_) {},
      onError: (Object _) {
        if (identical(_transport, transport)) _fail('诊断管道读取失败');
      },
    );
  }

  void _frame(String source) {
    final value = strictSupervisorObject(source);
    if (value['protocol'] is! int || value['protocol'] != 1) {
      throw protocolFailure;
    }
    _sameGeneration(value);
    if (state == SupervisorState.starting) {
      final type = _expected;
      if (type == null || value['type'] != type || _stage!.isCompleted) {
        throw protocolFailure;
      }
      final keys = type == 'core_ready'
          ? ['type', 'protocol', 'generation', 'launch', 'pid']
          : ['type', 'protocol', 'generation'];
      exactKeys(value, keys);
      final canonical = {for (final key in keys) key: value[key]};
      if (source != jsonEncode(canonical) ||
          utf8.encode(source).length > controlFrameLimit) {
        throw protocolFailure;
      }
      if (type == 'core_ready' &&
          (value['launch'] != _launch ||
              value['pid'] is! int ||
              (value['pid'] as int) <= 0 ||
              (value['pid'] as int) > 0x7fffffff)) {
        throw protocolFailure;
      }
      _stage!.complete(value);
      return;
    }
    if (value['type'] == 'relay_credit') {
      exactKeys(value, ['type', 'protocol', 'generation', 'sequence']);
      if (utf8.encode(source).length > controlFrameLimit ||
          source !=
              jsonEncode({
                'type': 'relay_credit',
                'protocol': 1,
                'generation': _generation,
                'sequence': value['sequence'],
              }) ||
          value['sequence'] is! int ||
          value['sequence'] != _awaitingCredit ||
          _creditReceived) {
        throw protocolFailure;
      }
      _creditReceived = true;
      if (!_writing && state == SupervisorState.ready) _grantCredit();
      return;
    }
    exactKeys(value, ['protocol', 'generation', 'result']);
    if (state != SupervisorState.ready) return;
    // 消费者Future不暂停reader；消费者错误只使用固定错误，不回显结果。
    final callbackEpoch = _epoch;
    unawaited(
      Future<void>.sync(() => onResult(value['result'])).catchError((Object _) {
        if (callbackEpoch == _epoch && state == SupervisorState.ready) {
          _fail('业务结果处理失败');
        }
      }),
    );
  }

  Future<void> sendAction({
    required String id,
    required String method,
    Object? data,
  }) {
    if (state != SupervisorState.ready || id.isEmpty || method.isEmpty) {
      return Future.error(const SupervisorFailure('控制会话未就绪'));
    }
    if (_queue.length + (_active == null ? 0 : 1) >= queueLimit) {
      return Future.error(const SupervisorFailure('控制会话发送队列已满'));
    }
    try {
      final item = _Submission(
        encodeSupervisorFrame({
          'protocol': 1,
          'generation': _generation,
          'action': {'id': id, 'method': method, 'data': data},
        }, businessFrameLimit),
      );
      _queue.add(item);
      _pump();
      return item.done.future;
    } catch (_) {
      return Future.error(protocolFailure);
    }
  }

  void _grantCredit() {
    _awaitingCredit = null;
    _creditReceived = false;
    _permit = true;
    _pump();
  }

  void _pump() {
    if (state != SupervisorState.ready ||
        !_permit ||
        _writing ||
        _queue.isEmpty) {
      return;
    }
    final item = _queue.removeFirst();
    _active = item;
    final epoch = _epoch;
    _permit = false;
    _writing = true;
    _awaitingCredit = ++_sequence;
    unawaited(() async {
      try {
        await _transport!.write(item.frame).timeout(startBudget);
        if (epoch != _epoch || state != SupervisorState.ready) {
          throw protocolFailure;
        }
        if (!item.done.isCompleted) item.done.complete();
      } catch (_) {
        if (!item.done.isCompleted) {
          item.done.completeError(const SupervisorFailure('业务帧写入失败'));
        }
        if (epoch == _epoch) _fail('业务帧写入失败');
      } finally {
        _writing = false;
        _active = null;
        if (_creditReceived && state == SupervisorState.ready) _grantCredit();
      }
    }());
  }

  void _fail(String message) {
    _sticky = true;
    error ??= message;
    state = SupervisorState.failed;
    if (_stage != null && !_stage!.isCompleted) {
      _stage!.completeError(protocolFailure);
    }
    unawaited(stop());
  }

  Future<void> _revoke() async {
    if (_launch == null || _revoked) return;
    await _worker(
      native.call('revokeLaunch', {
        'launch': _launch!,
        'generation': _generation,
      }),
    );
    _revoked = true;
  }

  // 已撤销的native bind仍记录实际helper出生，stale返回不能恢复proof。
  // 只发起有界停止证据工作；宿主不等待SDK返回才关闭pipe。
  void _recordCanceledHelper() {
    if (_helperBindingStarted || _launch == null || _transport == null) return;
    _helperBindingStarted = true;
    _ledgerFuture = _worker(
      native.call('bindSupervisor', {
        'launch': _launch!,
        'generation': _generation,
        'pid': _transport!.pid,
      }),
    ).then<void>((_) {}, onError: (Object _) {});
  }

  void _closeInput() {
    if (_transport == null || _inputClosed) return;
    _inputClosed = true;
    _inputClose = _transport!.closeInput().catchError((Object _) {
      _sticky = true;
      error ??= '控制管道关闭失败';
    });
  }

  Future<bool> stop() {
    if (_stopFuture != null) return _stopFuture!;
    if (state == SupervisorState.stopped && !hasUnconfirmedOwner) {
      return Future.value(true);
    }
    ++_epoch; // 先撤销意图，任何SDK/flush迟到都不能重建ready。
    state = SupervisorState.stopping;
    _permit = false;
    if (_stage != null && !_stage!.isCompleted) {
      _stage!.completeError(protocolFailure);
    }
    for (final item in [..._queue, ?_active]) {
      if (!item.done.isCompleted) {
        item.done.completeError(const SupervisorFailure('会话已撤销'));
      }
    }
    _queue.clear();
    final future = _stop();
    _stopFuture = future;
    unawaited(
      future.whenComplete(() {
        _stopFuture = null;
      }),
    );
    return future;
  }

  Future<bool> _stop() async {
    final watch = Stopwatch()..start();
    try {
      // host worker可能不返回；发起revoke后即关闭stdin，不等待SDK恢复。
      final revoke = _revoke();
      unawaited(
        revoke.catchError((Object _) {
          _sticky = true;
          error ??= '会话撤销失败';
        }),
      );
      _recordCanceledHelper();
      _closeInput();
      if (_exit == null) {
        if (_workers != 0 || _launch != null) throw protocolFailure;
        if (_sticky) throw protocolFailure;
        state = SupervisorState.stopped;
        return true;
      }
      final code = await _exit!.timeout(_remaining(watch, stopBudget));
      await revoke.timeout(_remaining(watch, stopBudget));
      if (_ledgerFuture != null) {
        await _ledgerFuture!.timeout(_remaining(watch, stopBudget));
      }
      if (_inputClose != null) {
        await _inputClose!.timeout(_remaining(watch, stopBudget));
      }
      if (_eofSignal != null) {
        await _eofSignal!.future.timeout(_remaining(watch, stopBudget));
      }
      final confirmed = await _worker(
        native.call('confirmStopped', {
          'launch': _launch!,
          'generation': _generation,
        }),
      ).timeout(_remaining(watch, stopBudget));
      // EOF单独观察，不把业务成功、helper exit或未知kernel读取当Core消失。
      if (confirmed != true ||
          code != 0 ||
          _exitError ||
          !_eof ||
          _sticky ||
          _workers != 0 ||
          _writing) {
        throw protocolFailure;
      }
      _transport = null;
      _exit = null;
      _handle = null;
      _launch = null;
      state = SupervisorState.stopped;
      return true;
    } catch (_) {
      state = SupervisorState.failed;
      error ??= '旧会话停止尚未确认';
      return false;
    }
  }
}
