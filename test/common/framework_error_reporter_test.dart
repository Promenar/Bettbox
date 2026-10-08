import 'package:bett_box/common/framework_error_reporter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnformattableException {
  @override
  String toString() => throw StateError('公开夹具禁止格式化');
}

class _FailingWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) => throw _UnformattableException();
}

void main() {
  test('真实框架回调报告固定失败类别，不格式化异常或堆栈', () {
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);
    final messages = <String>[];
    FrameworkErrorReporter(report: messages.add).install();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: _UnformattableException(),
        stack: StackTrace.fromString('PUBLIC_DIAGNOSTIC_FRAME'),
        library: 'PUBLIC_LIBRARY',
      ),
    );
    expect(messages, ['[界面] framework failed']);
  });

  test('诊断输出抛异常不得引入新的框架错误', () {
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);
    FrameworkErrorReporter(report: (_) => throw StateError('公开输出故障')).install();
    expect(
      () => FlutterError.reportError(
        FlutterErrorDetails(exception: _UnformattableException()),
      ),
      returnsNormally,
    );
  });

  testWidgets('实际组件构建失败通过已安装的框架入口报告', (tester) async {
    final previous = FlutterError.onError;
    final messages = <String>[];
    try {
      FrameworkErrorReporter(report: messages.add).install();
      await tester.pumpWidget(_FailingWidget());
      expect(messages, ['[界面] framework failed']);
      expect(find.byType(ErrorWidget), findsOneWidget);
    } finally {
      FlutterError.onError = previous;
    }
  });
}
