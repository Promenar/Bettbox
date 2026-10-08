import 'dart:async';
import 'dart:ui';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/smart_stop_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  for (final result in <bool?>[false, null, true]) {
    test('智能停止失败或挂起未确认不提交：$result', () async {
      var committed = false;
      await expectLater(
        completeSmartStop(
          stop: () async => result,
          isSuspended: () async => false,
          currentSession: () => null,
          commit: () => committed = true,
        ),
        throwsStateError,
      );
      expect(committed, isFalse);
    });
  }
  test('等待原生与挂起确认后才清理同一会话', () async {
    final stop = Completer<bool>();
    final suspended = Completer<bool>();
    final entered = Completer<void>();
    final session = Object();
    var committed = false;
    final completed = completeSmartStop(
      stop: () => stop.future,
      isSuspended: () {
        entered.complete();
        return suspended.future;
      },
      currentSession: () => session,
      commit: () => committed = true,
    );
    expect(committed, isFalse);
    stop.complete(true);
    await entered.future;
    expect(committed, isFalse);
    suspended.complete(true);
    await completed;
    expect(committed, isTrue);
  });
  test('旧停止回执不清理等待期间启动的新会话', () async {
    final stop = Completer<bool>();
    Object session = Object();
    var committed = false;
    final completed = completeSmartStop(
      stop: () => stop.future,
      isSuspended: () async => true,
      currentSession: () => session,
      commit: () => committed = true,
    );
    final rejected = expectLater(completed, throwsStateError);
    session = Object();
    stop.complete(true);
    await rejected;
    expect(committed, isFalse);
  });
  test('平台错误保留且不提交', () async {
    var committed = false;
    await expectLater(
      completeSmartStop(
        stop: () async => throw StateError('公开替身失败'),
        isSuspended: () async => true,
        currentSession: () => null,
        commit: () => committed = true,
      ),
      throwsStateError,
    );
    expect(committed, isFalse);
  });
}
