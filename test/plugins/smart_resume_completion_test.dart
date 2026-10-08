import 'dart:async';
import 'dart:ui';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/smart_stop_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  for (final value in <bool?>[false, null]) {
    test('恢复未确认保留停止显示：$value', () async {
      var committed = false;
      await expectLater(
        completeSmartResume(
          resume: () async => value,
          currentSession: () => null,
          commit: () => committed = true,
        ),
        throwsStateError,
      );
      expect(committed, isFalse);
    });
  }
  test('收到完成回执后才提交', () async {
    final response = Completer<bool>();
    var committed = false;
    final result = completeSmartResume(
      resume: () => response.future,
      currentSession: () => null,
      commit: () => committed = true,
    );
    expect(committed, isFalse);
    response.complete(true);
    await result;
    expect(committed, isTrue);
  });
  test('等待期间换会话拒绝旧恢复回执', () async {
    final response = Completer<bool>();
    Object? session;
    var committed = false;
    final result = completeSmartResume(
      resume: () => response.future,
      currentSession: () => session,
      commit: () => committed = true,
    );
    final rejected = expectLater(result, throwsStateError);
    session = Object();
    response.complete(true);
    await rejected;
    expect(committed, isFalse);
  });
  test('平台错误保留且不提交', () async {
    var committed = false;
    await expectLater(
      completeSmartResume(
        resume: () async => throw StateError('公开替身失败'),
        currentSession: () => null,
        commit: () => committed = true,
      ),
      throwsStateError,
    );
    expect(committed, isFalse);
  });
}
