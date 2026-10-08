import 'dart:async';
import 'dart:ui';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => AppLocalizations.load(const Locale('zh', 'CN')));
  const options = AndroidVpnOptions(
    enable: true,
    port: 7890,
    accessControl: null,
    allowBypass: false,
    systemProxy: false,
    bypassDomain: [],
    ipv4Address: '172.19.0.1/30',
    ipv6Address: '',
    dnsServerAddress: '172.19.0.2',
  );
  final clients = <String, Future<bool?> Function()>{
    'service': Service().smartResume,
    'vpn': () => Vpn().smartResume(options),
  };
  for (final entry in clients.entries) {
    final channel = MethodChannel(entry.key);
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    for (final response in <bool?>[false, null]) {
      test('${entry.key} 智能恢复拒绝未确认回执：$response', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(entry.value(), throwsStateError);
      });
    }
    test('${entry.key} 智能恢复等待平台回执', () async {
      final response = Completer<bool>();
      final entered = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            expect(call.method, 'smartResume');
            entered.complete();
            return response.future;
          });
      var completed = false;
      final result = entry.value().then((value) {
        completed = true;
        return value;
      });
      await entered.future;
      expect(completed, isFalse);
      response.complete(true);
      expect(await result, isTrue);
    });
  }
}
