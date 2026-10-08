import 'dart:async';
import 'dart:convert';

import 'supervisor_codec.dart';
import 'supervisor_events.dart';

typedef SupervisorRpcSender =
    Future<void> Function(String id, String method, Object? data);

class _Request {
  _Request(this.method);
  final String method;
  final result = Completer<void>();
  final cancellation = Completer<void>();
  Map<String, dynamic>? value;
  Timer? timer;
  int bytes = 0;
}

// 每代独立的请求表；超时不释放后继续发送，而是撤销整个会话。
class SupervisorRpc {
  SupervisorRpc({
    required this.generation,
    required this.send,
    required this.onFatal,
    required this.onEvent,
  }) {
    if (generation <= 0 || generation > 0x7fffffffffffffff) {
      throw const SupervisorFailure('请求代次无效');
    }
  }
  final int generation;
  final SupervisorRpcSender send;
  final void Function() onFatal;
  final SupervisorEventBatch Function(Map<String, Object?>) onEvent;
  static const pendingLimit = 8;
  static const resultByteLimit = 16 * 1024 * 1024;
  static const eventByteLimit = 1024 * 1024;
  static const eventConsumerLimit = 32;
  final _pending = <String, _Request>{};
  int _sequence = 0;
  int _resultBytes = 0;
  bool _closed = false;
  int _eventConsumers = 0;
  int _eventBytes = 0;

  int get pendingCount => _pending.length;
  int get retainedResultBytes => _resultBytes;
  bool get isClosed => _closed;
  bool get hasUnconfirmedConsumers => _eventConsumers != 0;

  Future<Map<String, dynamic>> request({
    required String method,
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed ||
        method.isEmpty ||
        method.length > 128 ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 60)) {
      throw const SupervisorFailure('请求通道不可用');
    }
    if (_pending.length >= pendingLimit) {
      throw const SupervisorFailure('在途请求已满');
    }
    final id = 'g$generation-r${++_sequence}';
    final item = _Request(method);
    _pending[id] = item;
    // 在调用sender之前安装错误观察，覆盖同步回包和极早失败。
    unawaited(item.result.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(
      item.cancellation.future.then<void>((_) {}, onError: (Object _) {}),
    );
    item.timer = Timer(timeout, () {
      if (identical(_pending[id], item)) {
        _fail(TimeoutException('内核请求超时'));
      }
    });
    final sending = Future<void>.sync(() => send(id, method, data)).catchError((
      Object _,
    ) {
      if (!_closed) _fail(const SupervisorFailure('内核请求发送失败'));
      throw const SupervisorFailure('内核请求发送失败');
    });
    try {
      // 回包可早于flush；两项均确认才交付，超时错误无需等待挂起sender。
      await Future.any<void>([
        Future.wait<void>([
          sending,
          item.result.future,
        ], eagerError: true).then<void>((_) {}),
        item.cancellation.future,
      ]);
      if (_closed) throw const SupervisorFailure('内核会话已撤销');
      return item.value!;
    } finally {
      item.timer?.cancel();
      if (identical(_pending[id], item)) {
        _pending.remove(id);
        _resultBytes -= item.bytes;
      }
      item.value = null;
    }
  }

  void receive(Object? raw) {
    if (_closed) return;
    try {
      const keys = {'id', 'method', 'data', 'code', 'Port'};
      if (raw is! Map ||
          raw.length != keys.length ||
          !raw.keys.every(keys.contains) ||
          raw['id'] is! String ||
          raw['method'] is! String ||
          raw['code'] is! int ||
          (raw['code'] != 0 && raw['code'] != -1) ||
          raw['Port'] is! int ||
          raw['Port'] != 0) {
        throw protocolFailure;
      }
      final result = Map<String, dynamic>.from(raw);
      final bytes = utf8.encode(jsonEncode(result)).length;
      if (result['method'] == 'message') {
        if (result['id'] != '' ||
            result['code'] != 0 ||
            result['data'] is! Map<String, dynamic> ||
            bytes > eventByteLimit) {
          throw protocolFailure;
        }
        // 事件同步交付，不积压异步controller；监听器错误撤销会话。
        if (_eventConsumers >= eventConsumerLimit ||
            _eventBytes + bytes > resultByteLimit) {
          throw protocolFailure;
        }
        final task = onEvent(Map<String, Object?>.from(result['data'] as Map));
        if (task.hasTasks) {
          _eventConsumers++;
          _eventBytes += bytes;
          unawaited(
            task.settled.then<void>((_) {
              _eventConsumers--;
              _eventBytes -= bytes;
            }),
          );
          unawaited(
            task.failure.then<void>((_) {
              _fail(const SupervisorFailure('内核事件消费失败'));
            }),
          );
        }
        return;
      }
      final item = _pending[result['id']];
      if (item == null ||
          item.result.isCompleted ||
          item.method != result['method'] ||
          bytes > businessFrameLimit ||
          _resultBytes + bytes > resultByteLimit) {
        throw protocolFailure;
      }
      item.bytes = bytes;
      _resultBytes += bytes;
      item.value = result;
      item.result.complete();
    } catch (_) {
      _fail(const SupervisorFailure('内核回包校验失败'));
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    close(error);
    // 回调只允许撤销，不授予身份或新建会话。
    try {
      onFatal();
    } catch (_) {}
  }

  void close([Object error = const SupervisorFailure('内核会话已撤销')]) {
    if (_closed) return;
    _closed = true;
    for (final item in _pending.values) {
      item.timer?.cancel();
      item.value = null;
      if (!item.cancellation.isCompleted) {
        item.cancellation.completeError(error);
      }
      if (!item.result.isCompleted) item.result.completeError(error);
    }
    // 总期限覆盖sender与result；取消Future不持有载荷，挂起sender不能保留结果。
  }
}
