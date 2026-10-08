import 'dart:async';
import 'dart:ui';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handler extends ClashHandlerInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  test('关联拒绝完成原请求的失败，不留悬挂或转换为成功', () async {
    final handler = _Handler();
    final completion = Completer<bool>();
    handler.callbackCompleterMap['public-init'] = completion;
    final checked = expectLater(completion.future, throwsStateError);
    await handler.handleResult(
      const ActionResult(
        id: 'public-init',
        method: ActionMethod.initClash,
        code: ResultType.error,
        data: null,
      ),
    );
    await checked;
  });
  test('成功和旧异次拒绝不污染当前请求', () async {
    final handler = _Handler();
    final completion = Completer<bool>();
    handler.callbackCompleterMap['current-init'] = completion;
    await handler.handleResult(
      const ActionResult(
        id: 'older-init',
        method: ActionMethod.initClash,
        code: ResultType.error,
        data: null,
      ),
    );
    expect(completion.isCompleted, isFalse);
    await handler.handleResult(
      const ActionResult(
        id: 'current-init',
        method: ActionMethod.initClash,
        data: true,
      ),
    );
    expect(await completion.future, isTrue);
  });
}
