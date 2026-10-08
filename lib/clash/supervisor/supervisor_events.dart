import 'dart:async';

// 失败信号与全部任务结束分开；错误不能清洗其它挂起消费者。
class SupervisorEventBatch {
  SupervisorEventBatch(Iterable<Future<void>> tasks) {
    final work = tasks.toList(growable: false);
    hasTasks = work.isNotEmpty;
    final observed = <Future<void>>[
      for (final task in work)
        task.then<void>(
          (_) {},
          onError: (Object _) {
            if (!_failed.isCompleted) _failed.complete();
          },
        ),
    ];
    settled = Future.wait<void>(observed).then<void>((_) {});
  }
  final _failed = Completer<void>();
  late final bool hasTasks;
  late final Future<void> settled;
  Future<void> get failure => _failed.future;
}
