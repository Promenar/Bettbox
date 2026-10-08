import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_application.dart';
import 'package:bett_box/clash/supervisor/supervisor_events.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'package:bett_box/clash/supervisor/supervisor_session.dart';
import 'package:bett_box/clash/supervisor/supervisor_system_proxy.dart';
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

// 公开替身仅控制回包及屏障，实际策略由生产Application执行。
class LifecycleSession extends TestSession {
  LifecycleSession(
    super.result,
    super.revoked,
    this.trace, {
    this.requireConfiguration = false,
  });
  final List<String> trace;
  final bool requireConfiguration;
  bool configurationReady = false;
  int generation = 0;
  int listenerEpoch = 0;
  bool endpointActive = false;
  bool restored = true;
  bool configured = true;
  Object? ownedStopReply;
  Object? endpointReply;
  Completer<void>? endpointBarrier;
  Completer<void>? recoveryBarrier;
  final endpointEntered = Completer<void>();
  final recoveryEntered = Completer<void>();

  @override
  Future<void> start(int value) async {
    generation = value;
    await super.start(value);
  }

  @override
  Future<bool> recoverSystemProxy() async {
    trace.add('restore');
    if (!recoveryEntered.isCompleted) recoveryEntered.complete();
    await recoveryBarrier?.future;
    return restored;
  }

  @override
  Future<SystemProxyResult> activateSystemProxy(
    OwnedHttpEndpoint endpoint,
    List<String> bypass,
  ) async {
    trace.add('activate:${endpoint.listenerEpoch}');
    return SystemProxyResult.fromReply({
      'status': 'applied',
      'transactionGeneration': 1,
      'changedGroups': 2,
      'unresolvedGroups': 0,
    });
  }

  @override
  Future<bool> stop() async {
    trace.add('core-stop');
    // RPC已close才应忽略事件，不能把Core停止之前的事件消费当作已结束。
    onResult({
      'id': '',
      'method': 'message',
      'data': <String, dynamic>{'type': 'loaded', 'data': 'public'},
      'code': 0,
      'Port': 0,
    });
    return super.stop();
  }

  @override
  Future<void> sendAction({
    required String id,
    required String method,
    Object? data,
  }) async {
    trace.add(method);
    Object? reply = true;
    if (method == 'ownedHttpStart' || method == 'ownedHttpGet') {
      expect(data, <String, Object>{});
      if (requireConfiguration &&
          method == 'ownedHttpStart' &&
          !configurationReady) {
        onResult({
          'id': id,
          'method': method,
          'data': '专用入口未就绪',
          'code': -1,
          'Port': 0,
        });
        return;
      }
      if (method == 'ownedHttpStart') {
        if (!endpointEntered.isCompleted) endpointEntered.complete();
        await endpointBarrier?.future;
        if (!endpointActive) listenerEpoch++;
        endpointActive = true;
      }
      reply =
          endpointReply ??
          {
            'generation': generation,
            'listenerEpoch': listenerEpoch,
            'host': '127.0.0.1',
            'port': 7890,
            'state': 'active',
          };
    } else if (method == 'ownedHttpStop') {
      expect(data, <String, Object>{});
      endpointActive = false;
      reply =
          ownedStopReply ??
          {
            'generation': generation,
            'listenerEpoch': listenerEpoch,
            'state': 'stopped',
          };
    } else if (method == 'setupConfig' || method == 'updateConfig') {
      // 配置RPC本身会销毁专用入口，不能由替身帮Application补恢复。
      endpointActive = false;
      reply = configured ? '' : '公开配置拒绝';
      configurationReady =
          configured && (method == 'setupConfig' || configurationReady);
    }
    onResult({'id': id, 'method': method, 'data': reply, 'code': 0, 'Port': 0});
  }
}

class LifecycleFixture {
  LifecycleFixture({
    bool throwRuntimeCallback = false,
    bool requireConfiguration = true,
  }) {
    app = SupervisorApplication(
      buildSession: (result, revoked) {
        final session = LifecycleSession(
          result,
          revoked,
          trace,
          requireConfiguration: requireConfiguration,
        );
        sessions.add(session);
        return session;
      },
      onEvent: (_) {
        trace.add('event-after-core-stop');
        return SupervisorEventBatch(const []);
      },
      onRuntimeChanged: (value) {
        runtimeEvents.add(value);
        if (throwRuntimeCallback) throw const SupervisorFailure('公开通知失败');
      },
    );
  }
  final trace = <String>[];
  final sessions = <LifecycleSession>[];
  final runtimeEvents = <DateTime?>[];
  late final SupervisorApplication app;
  LifecycleSession get session => sessions.last;
  Future<void> ready() async {
    await app.initialize();
    expect((await app.request(method: 'initClash'))['data'], true);
    expect(
      (await app.request(method: 'setupConfig', data: '公开配置'))['data'],
      '',
    );
    trace.clear();
  }

  Future<void> running() async {
    await ready();
    expect(
      await app.setSystemProxyPreference(
        enabled: true,
        bypass: const ['localhost'],
      ),
      true,
    );
    expect(await app.startRuntime(), true);
    expect(app.isRuntimeActive, true);
    expect(app.startedAt, isNotNull);
    trace.clear();
  }
}

void main() {
  group('生产Application系统代理事务红例', () {
    test('恢复失败保留RPC入口和Core且shutdown失败可重试', () async {
      final f = LifecycleFixture();
      await f.ready();
      f.session.restored = false;
      expect(await f.app.shutdown(), false);
      expect(f.session.stops, 0);
      expect(f.app.hasUnconfirmedOwner, true);
      expect(f.trace, ['restore']);
      // 能接收普通结果说明原RPC没有被不可逆关闭；重试仍使用同一会话。
      expect((await f.app.request(method: 'getIsInit'))['data'], true);
      f.session.restored = true;
      expect(await f.app.shutdown(), true);
      expect(f.sessions.length, 1);
    });

    test('正常shutdown严格恢复入口后关闭RPC再停止Core', () async {
      final f = LifecycleFixture();
      await f.running();
      expect(await f.app.shutdown(), true);
      expect(f.trace, ['restore', 'ownedHttpStop', 'core-stop']);
      expect(f.session.endpointActive, false);
      expect(f.app.isRuntimeActive, false);
      expect(f.app.startedAt, isNull);
      expect(f.app.hasUnconfirmedOwner, false);
      expect(f.runtimeEvents.first, isNotNull);
      expect(f.runtimeEvents.last, isNull);
    });

    test('停止立即撤销晚到入口启动且不能发布active', () async {
      final f = LifecycleFixture();
      await f.ready();
      expect(
        await f.app.setSystemProxyPreference(enabled: true, bypass: const []),
        true,
      );
      f.session.endpointBarrier = Completer<void>();
      final starting = f.app.startRuntime();
      await f.session.endpointEntered.future.timeout(
        const Duration(seconds: 1),
      );
      final stopping = f.app.stopRuntime();
      f.session.endpointBarrier!.complete();
      expect(await starting, false);
      expect(await stopping, true);
      expect(f.trace.where((value) => value.startsWith('activate:')), isEmpty);
      expect(f.session.endpointActive, false);
      expect(f.app.isRuntimeActive, false);
      expect(f.app.startedAt, isNull);
    });

    test('配置恢复未知不得发送会销毁入口的配置RPC', () async {
      final f = LifecycleFixture();
      await f.running();
      f.session.restored = false;
      await expectLater(
        f.app.request(method: 'updateConfig', data: '公开配置'),
        throwsA(isA<SupervisorFailure>()),
      );
      expect(f.trace, ['restore']);
      expect(f.session.endpointActive, true);
      expect(f.session.stops, 0);
      expect(f.app.hasUnconfirmedOwner, true);
    });

    test('配置成功先释放旧入口并使用新epoch恢复用户意图', () async {
      final f = LifecycleFixture();
      await f.running();
      final epoch = f.session.listenerEpoch;
      expect(
        (await f.app.request(method: 'setupConfig', data: '公开配置'))['data'],
        '',
      );
      expect(f.trace.take(3), ['restore', 'ownedHttpStop', 'setupConfig']);
      expect(f.session.listenerEpoch, greaterThan(epoch));
      expect(f.trace.last, 'activate:${f.session.listenerEpoch}');
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });

    test('关闭偏好不反向启动并保留运行意图', () async {
      final f = LifecycleFixture();
      await f.ready();
      expect(
        await f.app.setSystemProxyPreference(enabled: true, bypass: const []),
        true,
      );
      expect(f.trace, isEmpty);
      expect(f.app.isRuntimeActive, false);
      expect(await f.app.startRuntime(), true);
      f.trace.clear();
      expect(
        await f.app.setSystemProxyPreference(enabled: false, bypass: const []),
        true,
      );
      expect(f.trace.first, 'restore');
      expect(f.trace.any((value) => value.startsWith('activate:')), false);
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });

    test('运行通知错误不改变已确认入口和停止责任', () async {
      final f = LifecycleFixture(throwRuntimeCallback: true);
      await f.running();
      expect(f.session.endpointActive, true);
      expect(f.app.hasUnconfirmedOwner, true);
      expect(await f.app.shutdown(), true);
      expect(f.session.endpointActive, false);
      expect(f.app.hasUnconfirmedOwner, false);
      expect(f.runtimeEvents.last, isNull);
    });

    test('相同代理偏好不撤销正在执行的启动', () async {
      final f = LifecycleFixture();
      await f.ready();
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['localhost'],
        ),
        true,
      );
      f.session.endpointBarrier = Completer<void>();
      final starting = f.app.startRuntime();
      await f.session.endpointEntered.future.timeout(
        const Duration(seconds: 1),
      );
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['localhost'],
        ),
        true,
      );
      f.session.endpointBarrier!.complete();
      expect(await starting, true);
      expect(f.trace.where((value) => value.startsWith('activate:')).length, 1);
      expect(await f.app.shutdown(), true);
    });

    test('bypass变更恢复旧入口后使用新epoch且保持运行意图', () async {
      final f = LifecycleFixture();
      await f.running();
      final epoch = f.session.listenerEpoch;
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['*.public.example'],
        ),
        true,
      );
      expect(f.trace.take(2), ['restore', 'ownedHttpStop']);
      expect(f.session.listenerEpoch, greaterThan(epoch));
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });

    test('ownedStop错身份保留入口责任且确认后可重试', () async {
      final f = LifecycleFixture();
      await f.running();
      f.session.ownedStopReply = {
        'generation': 2,
        'listenerEpoch': f.session.listenerEpoch,
        'state': 'stopped',
      };
      expect(await f.app.stopRuntime(), false);
      expect(f.app.hasUnconfirmedOwner, true);
      expect(f.session.stops, 0);
      expect(f.app.startedAt, isNotNull);
      f.session.ownedStopReply = null;
      expect(await f.app.stopRuntime(), true);
      expect(f.app.startedAt, isNull);
      expect(await f.app.shutdown(), true);
    });

    test('RPCfatal不伪造ownedStop且仅出生确认后清除入口责任', () async {
      final f = LifecycleFixture();
      await f.running();
      f.session.stopConfirmed = false;
      f.session.onResult(<String, Object>{'invalid': true});
      await tick();
      expect(await f.app.stopRuntime(), false);
      expect(f.app.hasUnconfirmedOwner, true);
      expect(f.trace, isNot(contains('ownedHttpStop')));
      f.session.stopConfirmed = true;
      expect(await f.app.stopRuntime(), true);
      expect(f.app.startedAt, isNull);
      expect(f.trace, isNot(contains('ownedHttpStop')));
      expect(await f.app.shutdown(), true);
    });

    test('入口身份未知且恢复失败保留RPC直到恢复与出生确认', () async {
      final f = LifecycleFixture();
      await f.ready();
      f.session.endpointReply = <String, Object>{'invalid': true};
      f.session.restored = false;
      await expectLater(
        f.app.startRuntime(),
        throwsA(isA<SupervisorFailure>()),
      );
      expect(f.session.stops, 0);
      expect(f.app.hasUnconfirmedOwner, true);
      expect((await f.app.request(method: 'getIsInit'))['data'], true);
      expect(await f.app.shutdown(), false);
      expect(f.session.stops, 0);
      f.session.restored = true;
      expect(await f.app.shutdown(), true);
      expect(f.trace, isNot(contains('ownedHttpStop')));
      expect(f.app.hasUnconfirmedOwner, false);
    });

    test('满队列停止仍撤销启动并取消尚未进入的配置', () async {
      final f = LifecycleFixture();
      await f.ready();
      f.session.endpointBarrier = Completer<void>();
      final starting = f.app.startRuntime();
      await f.session.endpointEntered.future.timeout(
        const Duration(seconds: 1),
      );
      final queued = [
        for (var i = 0; i < 7; i++)
          f.app.request(method: 'setupConfig', data: '公开配置'),
      ];
      final rejected = [
        for (final request in queued)
          expectLater(request, throwsA(isA<SupervisorFailure>())),
      ];
      await expectLater(
        f.app.request(method: 'setupConfig', data: '公开配置'),
        throwsA(isA<SupervisorFailure>()),
      );
      final stopping = f.app.stopRuntime();
      f.session.endpointBarrier!.complete();
      expect(await starting, false);
      expect(await stopping, true);
      await Future.wait(rejected);
      expect(f.trace, isNot(contains('setupConfig')));
      expect(f.app.isRuntimeActive, false);
      expect(await f.app.shutdown(), true);
    });

    test('重启仅握手保留运行意图且配置成功后才恢复入口', () async {
      final f = LifecycleFixture(requireConfiguration: true);
      await f.app.initialize();
      expect((await f.app.request(method: 'initClash'))['data'], true);
      expect(f.session.configurationReady, false);
      expect(
        (await f.app.request(method: 'setupConfig', data: '公开配置'))['data'],
        '',
      );
      expect(f.session.configurationReady, true);
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['localhost'],
        ),
        true,
      );
      expect(await f.app.startRuntime(), true);
      final previous = f.session;
      f.trace.clear();

      await f.app.restart();
      expect(f.session, isNot(same(previous)));
      expect(f.session.configurationReady, false);
      expect(f.trace, isNot(contains('ownedHttpStart')));
      expect(f.app.isRuntimeActive, false);
      expect(f.app.startedAt, isNull);

      f.trace.clear();
      expect((await f.app.request(method: 'initClash'))['data'], true);
      expect(f.session.configurationReady, false);
      expect(f.trace, isNot(contains('ownedHttpStart')));
      expect(f.trace.any((value) => value.startsWith('activate:')), false);

      f.trace.clear();
      expect(
        (await f.app.request(method: 'setupConfig', data: '公开配置'))['data'],
        '',
      );
      expect(f.trace, contains('ownedHttpStart'));
      expect(f.trace.last, 'activate:${f.session.listenerEpoch}');
      expect(f.session.configurationReady, true);
      expect(f.app.isRuntimeActive, true);
      expect(f.app.startedAt, isNotNull);
      expect(await f.app.shutdown(), true);
    });

    test('初次init只确认初始化且未配置启动保留意图不释放会话', () async {
      final f = LifecycleFixture();
      await f.app.initialize();
      expect(await f.app.startRuntime(), false);
      expect(
        await f.app.setSystemProxyPreference(enabled: true, bypass: const []),
        true,
      );
      expect((await f.app.request(method: 'initClash'))['data'], true);
      expect(f.trace, isNot(contains('ownedHttpStart')));
      expect(f.session.stops, 0);
      expect(f.app.isReady, true);
      expect(f.app.isRuntimeActive, false);
      expect(
        (await f.app.request(method: 'setupConfig', data: '公开配置'))['data'],
        '',
      );
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });

    test('冷update空串不能提升本代配置事实或构造入口', () async {
      final f = LifecycleFixture();
      await f.app.initialize();
      expect((await f.app.request(method: 'initClash'))['data'], true);
      expect(await f.app.startRuntime(), false);
      expect(
        (await f.app.request(method: 'updateConfig', data: '公开更新'))['data'],
        '',
      );
      expect(f.session.configurationReady, false);
      expect(f.trace, isNot(contains('ownedHttpStart')));
      expect(f.session.stops, 0);
      expect(f.app.isRuntimeActive, false);
      expect(await f.app.shutdown(), true);
    });

    test('配置拒绝后update空串不能恢复就绪必须setup成功', () async {
      final f = LifecycleFixture();
      await f.running();
      f.session.configured = false;
      expect(
        (await f.app.request(method: 'updateConfig', data: '公开更新'))['data'],
        '公开配置拒绝',
      );
      f.trace.clear();
      f.session.configured = true;
      expect(
        (await f.app.request(method: 'updateConfig', data: '公开更新'))['data'],
        '',
      );
      expect(f.trace, isNot(contains('ownedHttpStart')));
      expect(f.app.isRuntimeActive, false);
      expect(
        (await f.app.request(method: 'setupConfig', data: '公开配置'))['data'],
        '',
      );
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });

    test('偏好恢复失败后同值重试必须实际恢复并构造新epoch', () async {
      final f = LifecycleFixture();
      await f.running();
      final epoch = f.session.listenerEpoch;
      f.session.restored = false;
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['*.public.example'],
        ),
        false,
      );
      expect(f.trace, ['restore']);
      f.session.restored = true;
      f.trace.clear();
      expect(
        await f.app.setSystemProxyPreference(
          enabled: true,
          bypass: const ['*.public.example'],
        ),
        true,
      );
      expect(f.trace.take(2), ['restore', 'ownedHttpStop']);
      expect(f.session.listenerEpoch, greaterThan(epoch));
      expect(f.trace.last, 'activate:${f.session.listenerEpoch}');
      expect(f.app.isRuntimeActive, true);
      expect(await f.app.shutdown(), true);
    });
  });

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
