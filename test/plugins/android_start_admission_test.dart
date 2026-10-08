import 'dart:async';
import 'dart:ui';

import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  const channel = MethodChannel('service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final response in <bool?>[false, null]) {
    test('启动未获原生接纳时中止后续调用：$response', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'startVpn');
        return response;
      });
      var continued = false;
      final request = Service().startVpn().then((_) => continued = true);
      await expectLater(request, throwsStateError);
      expect(continued, isFalse);
    });
  }

  test('启动等待原生接纳响应', () async {
    final entered = Completer<void>();
    final response = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'startVpn');
      entered.complete();
      return response.future;
    });
    var returned = false;
    final request = Service().startVpn().then((value) {
      returned = true;
      return value;
    });
    await entered.future;
    expect(returned, isFalse);
    response.complete(true);
    expect(await request, isTrue);
  });

  test('启动保留平台错误', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'PUBLIC_FIXTURE_REJECTED'),
    );
    await expectLater(Service().startVpn(), throwsA(isA<PlatformException>()));
  });
}
