import 'dart:async';

/// 启动日志只接受固定阶段，不接收账户、异常或原生参数内容。
enum StartupStage {
  singleInstance,
  version,
  configuration,
  corePreload,
  dashboardAssets,
  rustBridge,
  androidBridge,
  window,
  application,
  firstFrame,
}

enum StartupPhase { begin, pending, complete, failed }

class StartupTrace {
  StartupTrace({
    required void Function(String) report,
    this.pendingAfter = const Duration(seconds: 10),
  }) : _report = report;

  final void Function(String) _report;
  final Duration pendingAfter;

  void _emit(StartupStage stage, StartupPhase phase, int elapsed) {
    try {
      _report('[启动] ${stage.name} ${phase.name} ${elapsed}ms');
    } catch (_) {
      // 诊断输出故障不改变原初始化结果。
    }
  }

  void mark(StartupStage stage) => _emit(stage, StartupPhase.complete, 0);

  Future<T> run<T>(StartupStage stage, Future<T> Function() operation) async {
    final clock = Stopwatch()..start();
    _emit(stage, StartupPhase.begin, 0);
    final timer = Timer(pendingAfter, () {
      _emit(stage, StartupPhase.pending, clock.elapsedMilliseconds);
    });
    try {
      final result = await operation();
      _emit(stage, StartupPhase.complete, clock.elapsedMilliseconds);
      return result;
    } catch (_) {
      _emit(stage, StartupPhase.failed, clock.elapsedMilliseconds);
      rethrow;
    } finally {
      timer.cancel();
      clock.stop();
    }
  }
}
