import 'dart:async';
import 'dart:isolate';

/// 持有一次实际原生动作的端口和截止时间，所有终态均关闭端口。
class NativeActionRequest {
  final _port = ReceivePort();
  final _result = Completer<String>();
  final _closed = Completer<void>();
  Timer? _timer;

  Future<String> get result => _result.future;
  Future<void> get closed => _closed.future;

  NativeActionRequest({Duration? timeout}) {
    _port.listen(
      (message) {
        if (_result.isCompleted) return;
        if (message is String) {
          _result.complete(message);
        } else {
          _result.completeError(StateError('内核动作回执无效'));
        }
        _finish();
      },
      onDone: () {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
    if (timeout != null) {
      _timer = Timer(timeout, () {
        if (!_result.isCompleted) {
          _result.completeError(TimeoutException('内核动作回执超时'));
        }
        _finish();
      });
    }
  }

  void send(void Function(SendPort) invoke) {
    try {
      invoke(_port.sendPort);
    } catch (error, stack) {
      if (!_result.isCompleted) _result.completeError(error, stack);
      _finish();
    }
  }

  void _finish() {
    _timer?.cancel();
    _port.close();
  }
}
