import 'dart:async';

import 'package:bett_box/common/startup_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('成功返回原值且完成后取消等待提示', (tester) async {
    final logs = <String>[];
    final trace = StartupTrace(report: logs.add);
    int? value;
    trace
        .run(StartupStage.configuration, () async => 42)
        .then((v) => value = v);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(value, 42);
    expect(logs, hasLength(2));
    expect(logs.first, contains('configuration begin'));
    expect(logs.last, contains('configuration complete'));
  });

  test('失败传播原异常但日志没有异常内容', () async {
    final logs = <String>[];
    final trace = StartupTrace(report: logs.add);
    final failure = StateError('秘密测试标记');
    await expectLater(
      trace.run(StartupStage.corePreload, () async => throw failure),
      throwsA(same(failure)),
    );
    expect(logs.last, contains('corePreload failed'));
    expect(logs.join(), isNot(contains('秘密测试标记')));
  });

  testWidgets('未返回操作提示等待但不取消或伪造完成', (tester) async {
    final logs = <String>[];
    final operation = Completer<int>();
    bool completed = false;
    final trace = StartupTrace(report: logs.add);
    trace
        .run(StartupStage.window, () => operation.future)
        .then((_) => completed = true);
    await tester.pump(const Duration(seconds: 10));
    expect(completed, false);
    expect(logs.last, contains('window pending'));
    operation.complete(1);
    await tester.pump();
    expect(completed, true);
    expect(logs.last, contains('window complete'));
  });

  test('日志故障不阻断操作，首帧只有固定标记', () async {
    final trace = StartupTrace(report: (_) => throw StateError('输出故障'));
    expect(await trace.run(StartupStage.version, () async => 7), 7);
    final logs = <String>[];
    StartupTrace(report: logs.add).mark(StartupStage.firstFrame);
    expect(logs.single, '[启动] firstFrame complete 0ms');
  });
}
