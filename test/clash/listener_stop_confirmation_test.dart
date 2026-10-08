import 'dart:async';
import 'dart:ui';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

class ListenerHandler extends ClashHandlerInterface {
  final Future<bool> Function() stop;
  int calls = 0;
  ListenerHandler(this.stop);

  @override
  Future<bool> stopListener() {
    calls++;
    return stop();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppLocalizations.load(const Locale('zh', 'CN')));

  test('公开停止入口不吞掉检查式关闭失败', () async {
    final handler = ListenerHandler(() async => false);
    await expectLater(ClashCore.withInterface(handler).stopListener(), throwsStateError);
    expect(handler.calls, 1);
  });

  test('公开停止入口等待关闭确认', () async {
    final closed = Completer<bool>();
    final handler = ListenerHandler(() => closed.future);
    var completed = false;
    final result = ClashCore.withInterface(handler).stopListener().then((_) { completed = true; });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    closed.complete(true);
    await result;
    expect(completed, isTrue);
    expect(handler.calls, 1);
  });

  test('公开停止入口保留关闭异常', () async {
    final handler = ListenerHandler(() async => throw StateError('公开关闭异常'));
    await expectLater(ClashCore.withInterface(handler).stopListener(), throwsStateError);
    expect(handler.calls, 1);
  });
}
