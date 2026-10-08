import 'dart:async';
import 'dart:ui';

import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  final clients = <String, Future<bool?> Function()>{
    'service': Service().stopVpn,
    'vpn': Vpn().stop,
    'serviceSmart': Service().smartStop,
    'vpnSmart': Vpn().smartStop,
  };
  for (final entry in clients.entries) {
    final channel = MethodChannel(
      entry.key.startsWith('service') ? 'service' : 'vpn',
    );
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    test('${entry.key} 停止拒绝失败与空回执', () async {
      for (final response in <bool?>[false, null]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(entry.value(), throwsA(isA<StateError>()));
      }
    });
    test('${entry.key} 停止等待同次原生完成', () async {
      final response = Completer<bool>();
      final invoked = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            expect(
              call.method,
              entry.key.endsWith('Smart')
                  ? 'smartStop'
                  : entry.key == 'vpn'
                  ? 'stop'
                  : 'stopVpn',
            );
            invoked.complete();
            return response.future;
          });
      var completed = false;
      final result = entry.value().then((value) {
        completed = true;
        return value;
      });
      await invoked.future;
      expect(completed, isFalse);
      response.complete(true);
      expect(await result, isTrue);
      expect(completed, isTrue);
    });
    test('${entry.key} 停止保留平台错误', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'UNKNOWN'),
          );
      await expectLater(entry.value(), throwsA(isA<PlatformException>()));
    });
  }
}
