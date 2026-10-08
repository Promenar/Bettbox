import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/message.dart';
import 'package:bett_box/models/core.dart';
import 'package:bett_box/clash/supervisor/supervisor_application.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'supervisor_application_test.dart' show TestSession;

class PendingListener with AppMessageListener {
  final completion = Completer<void>();
  @override
  Future<void> onLoaded(String providerName) => completion.future;
}

class ThrowingListener with AppMessageListener {
  @override
  void onLoaded(String providerName) {
    throw StateError('公开派发错误');
  }
}

void main() {
  test('派发中途同步错误不能丢弃先前已启动的真实监听器Future', () async {
    final pending = PendingListener();
    final throwing = ThrowingListener();
    clashMessage.addListener(pending);
    clashMessage.addListener(throwing);
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked);
        sessions.add(session);
        return session;
      },
      onEvent: clashMessage.dispatch,
    );
    try {
      await app.initialize();
      sessions.first.onResult({
        'id': '',
        'method': 'message',
        'data': <String, dynamic>{'type': 'loaded', 'data': 'public'},
        'code': 0,
        'Port': 0,
      });
      await Future<void>.delayed(Duration.zero);
      expect(await app.shutdown(), false);
      await expectLater(app.restart(), throwsA(isA<SupervisorFailure>()));
      expect(sessions.length, 1);
    } finally {
      pending.completion.complete();
      clashMessage.removeListener(pending);
      clashMessage.removeListener(throwing);
      await Future<void>.delayed(Duration.zero);
      await app.shutdown();
    }
  });
}
