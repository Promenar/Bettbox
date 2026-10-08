import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_application.dart';
import 'package:bett_box/clash/supervisor/supervisor_events.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'package:bett_box/clash/supervisor/supervisor_session.dart';
import 'supervisor_session_test.dart'
    show FakeNative, FakeFactory, FakeTransport;

// 只替换原生会话证据以验证生产协调器策略，不作为真实退出证据。
class TestSession extends SupervisorSession {
  TestSession(void Function(Object?) result, void Function() revoked)
    : super(
        native: FakeNative(),
        factory: FakeFactory(FakeTransport()),
        onResult: result,
        onRevoked: revoked,
      );
  bool failStart = false;
  bool owner = false;
  bool stopConfirmed = true;
  Completer<void>? startBarrier;
  Completer<void>? stopBarrier;
  int starts = 0;
  int stops = 0;
  @override
  bool get hasUnconfirmedOwner => owner;
  @override
  Future<void> start(int generation) async {
    starts++;
    state = SupervisorState.starting;
    await startBarrier?.future;
    if (failStart) {
      state = SupervisorState.failed;
      throw const SupervisorFailure('公开启动失败');
    }
    owner = true;
    state = SupervisorState.ready;
  }

  @override
  Future<bool> stop() async {
    stops++;
    onRevoked?.call();
    await stopBarrier?.future;
    if (!stopConfirmed) {
      state = SupervisorState.failed;
      return false;
    }
    owner = false;
    state = SupervisorState.stopped;
    return true;
  }

  @override
  Future<void> sendAction({
    required String id,
    required String method,
    Object? data,
  }) async {
    onResult({'id': id, 'method': method, 'data': false, 'code': 0, 'Port': 0});
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('Core停止确认不能清洗尚未结束的事件消费者', () async {
    final events = Completer<void>();
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked);
        sessions.add(session);
        return session;
      },
      onEvent: (_) => SupervisorEventBatch([events.future]),
    );
    await app.initialize();
    sessions.first.onResult({
      'id': '',
      'method': 'message',
      'data': <String, dynamic>{'type': 'loaded', 'data': 'public'},
      'code': 0,
      'Port': 0,
    });
    expect(await app.shutdown(), false);
    await expectLater(app.restart(), throwsA(isA<SupervisorFailure>()));
    expect(sessions.length, 1);
    events.complete();
    await tick();
    await app.restart();
    expect(sessions.length, 2);
    expect(await app.shutdown(), true);
  });

  test('首次失败后确认停止并成功重启，请求依据当前会话而非旧错误', () async {
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked)
          ..failStart = sessions.isEmpty;
        sessions.add(session);
        return session;
      },
      onEvent: (_) => SupervisorEventBatch(const []),
    );
    await expectLater(app.initialize(), throwsA(isA<SupervisorFailure>()));
    expect(await app.preload(), false);
    await app.restart();
    expect(await app.preload(), true);
    expect((await app.request(method: 'getIsInit'))['data'], false);
    expect(app.generation, 2);
    expect(await app.shutdown(), true);
  });

  test('shutdown撤销正在等待旧停止的restart，不新建helper', () async {
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked);
        sessions.add(session);
        return session;
      },
      onEvent: (_) => SupervisorEventBatch(const []),
    );
    await app.initialize();
    sessions.first.stopBarrier = Completer<void>();
    final restart = app.restart();
    final rejected = expectLater(restart, throwsA(isA<SupervisorFailure>()));
    await tick();
    final shutdown = app.shutdown();
    sessions.first.stopBarrier!.complete();
    await rejected;
    expect(await shutdown, true);
    expect(sessions.length, 1);
    expect(app.isReady, false);
    expect(app.hasUnconfirmedOwner, false);
  });

  test('停止证据未知保留原会话，不创建新代次', () async {
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked);
        sessions.add(session);
        return session;
      },
      onEvent: (_) => SupervisorEventBatch(const []),
    );
    await app.initialize();
    sessions.first.stopConfirmed = false;
    await expectLater(app.restart(), throwsA(isA<SupervisorFailure>()));
    expect(app.hasUnconfirmedOwner, true);
    expect(sessions.length, 1);
    expect(app.generation, 1);
    expect(await app.shutdown(), false);
  });

  test('初始化等待也受八请求限制，关闭后全部拒绝并释放准入', () async {
    final barrier = Completer<void>();
    final sessions = <TestSession>[];
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = TestSession(result, revoked)..startBarrier = barrier;
        sessions.add(session);
        return session;
      },
      onEvent: (_) => SupervisorEventBatch(const []),
    );
    final initial = app.initialize();
    unawaited(initial.then<void>((_) {}, onError: (Object _) {}));
    await tick();
    final requests = [
      for (var i = 0; i < 8; i++) app.request(method: 'getIsInit'),
    ];
    final rejected = [
      for (final request in requests)
        expectLater(request, throwsA(isA<SupervisorFailure>())),
    ];
    await expectLater(
      app.request(method: 'getIsInit'),
      throwsA(isA<SupervisorFailure>()),
    );
    expect(app.requestCount, 8);
    final shutdown = app.shutdown();
    barrier.complete();
    await expectLater(initial, throwsA(isA<SupervisorFailure>()));
    await Future.wait(rejected);
    await shutdown;
    expect(app.requestCount, 0);
    expect(sessions.length, 1);
    expect(app.isReady, false);
  });

  test('排队restart有界且shutdown使所有旧意图终止', () async {
    final barrier = Completer<void>();
    var built = 0;
    final app = SupervisorApplication(
      buildSession: (result, revoked) {
        built++;
        return TestSession(result, revoked)..startBarrier = barrier;
      },
      onEvent: (_) => SupervisorEventBatch(const []),
    );
    final initial = app.initialize();
    unawaited(initial.then<void>((_) {}, onError: (Object _) {}));
    await tick();
    final queued = [initial, for (var i = 0; i < 7; i++) app.restart()];
    final rejected = [
      for (final f in queued) expectLater(f, throwsA(isA<SupervisorFailure>())),
    ];
    await expectLater(app.restart(), throwsA(isA<SupervisorFailure>()));
    final shutdown = app.shutdown();
    barrier.complete();
    await Future.wait(rejected);
    await shutdown;
    expect(built, 1);
    expect(app.isReady, false);
  });
}
