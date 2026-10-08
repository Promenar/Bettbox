import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'package:bett_box/clash/supervisor/supervisor_application.dart';
import 'package:bett_box/clash/supervisor/supervisor_events.dart';
import 'package:bett_box/clash/supervisor/supervisor_native.dart';
import 'package:bett_box/clash/supervisor/supervisor_session.dart';
import 'package:bett_box/clash/supervisor/supervisor_transport.dart';
import 'package:bett_box/clash/supervisor/supervisor_system_proxy.dart';

const launch = '12345678-1234-1234-1234-123456789abc';
Future<void> tick() => Future<void>.delayed(Duration.zero);
Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await tick();
  }
  fail('场景未达到预期阶段');
}

class FakeNative implements SupervisorNative {
  final calls = <String>[];
  Completer<Object?>? binding;
  Completer<Object?>? reservation;
  bool confirmed = true;
  bool preflightRejected = false;
  bool preflightStopped = false;
  Completer<Object?>? preflightConfirmation;
  bool revoked = false;
  int issuedHelperProofs = 0;
  int generation = 1;
  final delays = <String, Duration>{};
  String proxyRecoveryStatus = 'idle';
  Completer<Object?>? proxyRecovery;
  @override
  Future<Object?> call(String method, Map<String, Object> args) async {
    calls.add(method);
    final delay = delays[method];
    if (delay != null) await Future<void>.delayed(delay);
    switch (method) {
      case 'recoverSystemProxy':
        if (proxyRecovery != null) return proxyRecovery!.future;
        return {
          'status': proxyRecoveryStatus,
          'transactionGeneration': 0,
          'changedGroups': 0,
          'unresolvedGroups': proxyRecoveryStatus == 'conflict' ? 1 : 0,
        };
      case 'reserveSupervisorLaunch':
        if (preflightRejected) throw const SupervisorFailure('公开预检拒绝');
        generation = args['generation'] as int;
        if (reservation != null) return reservation!.future;
        return {
          'launch': launch,
          'generation': args['generation'],
          'path': '/fixture/BettboxCoreSupervisor',
        };
      case 'bindSupervisor':
        if (revoked) throw const SupervisorFailure('旧launch已撤销，仅记录出生');
        issuedHelperProofs++;
        if (binding != null) return binding!.future;
        return {'handle': 'supervisor-handle', 'generation': generation};
      case 'bindCoreChain':
        return {'handle': 'core-handle', 'generation': generation};
      case 'recheckCoreChain':
        return {'valid': true, 'generation': generation};
      case 'revokeLaunch':
        revoked = true;
        return null;
      case 'confirmPreflightStopped':
        if (preflightConfirmation != null) return preflightConfirmation!.future;
        return preflightStopped;
      case 'confirmStopped':
        return confirmed;
    }
    throw const SupervisorFailure('未知原生方法');
  }
}

class FakeTransport implements SupervisorTransport {
  final stdout = StreamController<List<int>>(sync: true);
  final stderr = StreamController<List<int>>(sync: true);
  final exited = Completer<int>();
  final frames = <Map<String, dynamic>>[];
  bool wrongLaunch = false;
  int generation = 1;
  bool exitBeforeEof = false;
  bool closeObserved = false;
  Completer<void>? blockedWrite;
  @override
  int get pid => 101;
  @override
  Stream<List<int>> get output => stdout.stream;
  @override
  Stream<List<int>> get diagnostics => stderr.stream;
  @override
  Future<int> get exitCode => exited.future;
  void emit(Map<String, dynamic> frame) =>
      stdout.add(encodeSupervisorFrame(frame, businessFrameLimit));
  void credit(int sequence) => emit({
    'type': 'relay_credit',
    'protocol': 1,
    'generation': 1,
    'sequence': sequence,
  });
  int get businessCount =>
      frames.where((value) => value.containsKey('action')).length;
  @override
  Future<void> write(Uint8List frame) async {
    final value = strictSupervisorObject(utf8.decode(frame.sublist(4)));
    frames.add(value);
    if (value['type'] == 'prepare_core') {
      Timer.run(
        () => emit({
          'type': 'core_ready',
          'protocol': 1,
          'generation': generation,
          'launch': wrongLaunch
              ? '00000000-0000-0000-0000-000000000000'
              : launch,
          'pid': 102,
        }),
      );
    } else if (value['type'] == 'hello') {
      Timer.run(
        () => emit({'type': 'ack', 'protocol': 1, 'generation': generation}),
      );
    } else if (value.containsKey('action') && blockedWrite != null) {
      await blockedWrite!.future;
    }
  }

  @override
  Future<void> closeInput() async {
    if (closeObserved) return;
    closeObserved = true;
    if (exitBeforeEof && !exited.isCompleted) exited.complete(0);
    await stdout.close();
    await stderr.close();
    if (!exited.isCompleted) exited.complete(0);
  }
}

class FakeFactory implements SupervisorTransportFactory {
  FakeFactory(this.transport);
  final FakeTransport transport;
  int starts = 0;
  Completer<SupervisorTransport>? delayedSpawn;
  @override
  Future<SupervisorTransport> spawn(String path, int generation) async {
    starts++;
    transport.generation = generation;
    if (delayedSpawn != null) return delayedSpawn!.future;
    Timer.run(
      () => transport.emit({
        'type': 'supervisor_ready',
        'protocol': 1,
        'generation': generation,
      }),
    );
    return transport;
  }
}

void main() {
  group('生产codec', () {
    test('逐字节拆包、连续帧与最大有界分配', () {
      final values = <String>[];
      final reader = SupervisorFrameReader(() => controlFrameLimit, values.add);
      final frame = encodeSupervisorFrame({
        'type': 'ack',
        'protocol': 1,
        'generation': 1,
      }, controlFrameLimit);
      for (final byte in [...frame, ...frame]) {
        reader.add([byte]);
      }
      reader.finish();
      expect(values.length, 2);
    });
    test('零帧、超限、半帧和UTF8污染拒绝', () {
      for (final bytes in [
        <int>[0, 0, 0, 0],
        <int>[1, 16, 0, 0],
        <int>[1, 0, 0, 0, 255],
      ]) {
        final reader = SupervisorFrameReader(() => controlFrameLimit, (_) {});
        expect(() => reader.add(bytes), throwsA(isA<SupervisorFailure>()));
      }
      final reader = SupervisorFrameReader(() => controlFrameLimit, (_) {});
      reader.add([2, 0, 0, 0, 123]);
      expect(reader.finish, throwsA(isA<SupervisorFailure>()));
    });
    test('重复键、尾随对象和非对象拒绝', () {
      for (final source in [
        '{"protocol":1,"protocol":1}',
        '{"x":{"a":1,"a":2}}',
        '{}{}',
        '[]',
      ]) {
        expect(
          () => strictSupervisorObject(source),
          throwsA(isA<SupervisorFailure>()),
        );
      }
    });
  });

  group('生产SupervisorSession', () {
    late FakeNative native;
    late FakeTransport transport;
    late FakeFactory factory;
    late SupervisorSession session;
    setUp(() {
      native = FakeNative();
      transport = FakeTransport();
      factory = FakeFactory(transport);
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) {},
      );
    });

    test('恢复冲突保留Core和stdin且允许恢复后重试停止', () async {
      await session.start(1);
      native.proxyRecoveryStatus = 'conflict';
      expect(await session.stop(), false);
      expect(native.calls, contains('recoverSystemProxy'));
      expect(native.calls, isNot(contains('revokeLaunch')));
      expect(transport.closeObserved, false);
      expect(session.hasUnconfirmedOwner, true);
      native.proxyRecoveryStatus = 'restored';
      expect(await session.stop(), true);
      expect(transport.closeObserved, true);
    });

    test('等待恢复时不能提前撤权或关闭stdin', () async {
      await session.start(1);
      native.proxyRecovery = Completer<Object?>();
      final stopping = session.stop();
      await until(() => native.calls.contains('recoverSystemProxy'));
      expect(native.calls, isNot(contains('revokeLaunch')));
      expect(transport.closeObserved, false);
      native.proxyRecovery!.complete({
        'status': 'restored',
        'transactionGeneration': 1,
        'changedGroups': 2,
        'unresolvedGroups': 0,
      });
      expect(await stopping, true);
    });

    test('恢复超时保留底层single-flight并阻止并发activate', () async {
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) {},
        stopBudget: const Duration(milliseconds: 10),
      );
      await session.start(1);
      native.proxyRecovery = Completer<Object?>();
      expect(await session.recoverSystemProxy(), false);
      expect(await session.recoverSystemProxy(), false);
      expect(
        native.calls.where((value) => value == 'recoverSystemProxy').length,
        1,
      );
      await expectLater(
        session.activateSystemProxy(
          OwnedHttpEndpoint.fromReply({
            'generation': 1,
            'listenerEpoch': 1,
            'host': '127.0.0.1',
            'port': 7890,
            'state': 'active',
          }, generation: 1),
          const [],
        ),
        throwsA(isA<SupervisorFailure>()),
      );
      expect(native.calls, isNot(contains('activateOwnedSystemProxy')));
      native.proxyRecovery!.complete({
        'status': 'idle',
        'transactionGeneration': 0,
        'changedGroups': 0,
        'unresolvedGroups': 0,
      });
      await tick();
      expect(await session.stop(), true);
    });

    test('未发行预检失败仅在原生确认后允许实际Session停止及重试', () async {
      native.preflightRejected = true;
      await expectLater(session.start(1), throwsA(isA<SupervisorFailure>()));
      await tick();
      expect(factory.starts, 0);
      expect(await session.stop(), false);
      native.preflightStopped = true;
      expect(await session.stop(), true);
      expect(session.state, SupervisorState.stopped);
      native.preflightRejected = false;
      await session.start(2);
      expect(factory.starts, 1);
      expect(session.state, SupervisorState.ready);
      expect(await session.stop(), true);
    });

    test('停止确认迟到保持worker所有权且不提前释放失败会话', () async {
      native.preflightRejected = true;
      native.preflightConfirmation = Completer<Object?>();
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) {},
        stopBudget: const Duration(milliseconds: 25),
      );
      await expectLater(session.start(1), throwsA(isA<SupervisorFailure>()));
      expect(await session.stop(), false);
      expect(session.hasUnconfirmedOwner, true);
      expect(factory.starts, 0);
      native.preflightConfirmation!.complete(true);
      await tick();
      native.preflightConfirmation = null;
      native.preflightStopped = true;
      expect(await session.stop(), true);
    });

    test('实际Application使用实际Session在预检拒绝后重试更高代次', () async {
      native.preflightRejected = true;
      var builds = 0;
      final app = SupervisorApplication(
        buildSession: (result, revoked) {
          builds++;
          return SupervisorSession(
            native: native,
            factory: FakeFactory(FakeTransport()),
            onResult: result,
            onRevoked: revoked,
          );
        },
        onEvent: (_) => SupervisorEventBatch([]),
      );
      await expectLater(app.initialize(), throwsA(isA<SupervisorFailure>()));
      expect(await app.preload(), false);
      await expectLater(app.restart(), throwsA(isA<SupervisorFailure>()));
      expect(builds, 1);
      native.preflightStopped = true;
      native.preflightRejected = false;
      await app.restart();
      expect(builds, 2);
      expect(app.generation, 2);
      expect(await app.preload(), true);
      expect(await app.shutdown(), true);
    });

    test('停止立即同步通知请求消费者并合并重复stop', () async {
      var revoked = 0;
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) {},
        onRevoked: () {
          revoked++;
        },
      );
      await session.start(1);
      final first = session.stop();
      expect(revoked, 1);
      final second = session.stop();
      expect(identical(first, second), true);
      expect(await first, true);
      expect(revoked, 1);
    });

    test('真实入口握手顺序、正常EOF早于exit0、出生消失确认', () async {
      await session.start(1);
      expect(session.state, SupervisorState.ready);
      expect(native.calls.take(4), [
        'reserveSupervisorLaunch',
        'bindSupervisor',
        'bindCoreChain',
        'recheckCoreChain',
      ]);
      expect(transport.frames.map((frame) => frame['type']), [
        'prepare_core',
        'hello',
      ]);
      expect(await session.stop(), true);
      expect(session.state, SupervisorState.stopped);
      expect(session.hasUnconfirmedOwner, false);
    });

    test('exit0早于EOF仍等待管道结束', () async {
      transport.exitBeforeEof = true;
      await session.start(1);
      expect(await session.stop(), true);
    });

    test('未知出生消失保留Process与handle且禁止新启动', () async {
      await session.start(1);
      native.confirmed = false;
      expect(await session.stop(), false);
      expect(session.hasUnconfirmedOwner, true);
      await expectLater(session.start(2), throwsA(isA<SupervisorFailure>()));
      expect(factory.starts, 1);
    });

    test('credit背压及8项队列上限', () async {
      await session.start(1);
      await session.sendAction(id: 'first', method: 'getIsInit');
      final queued = [
        for (var i = 0; i < 8; i++)
          session.sendAction(id: 'q$i', method: 'getIsInit'),
      ];
      final watched = [
        for (final future in queued)
          future.then((_) {}, onError: (Object _) {}),
      ];
      await tick();
      expect(transport.businessCount, 1);
      await expectLater(
        session.sendAction(id: 'overflow', method: 'getIsInit'),
        throwsA(isA<SupervisorFailure>()),
      );
      transport.credit(1);
      await until(() => transport.businessCount == 2);
      expect(transport.businessCount, 2);
      expect(await session.stop(), true);
      await Future.wait(watched);
    });

    test('credit重复不能获得第二个许可', () async {
      await session.start(1);
      await session.sendAction(id: 'a', method: 'getIsInit');
      transport.credit(1);
      transport.credit(1);
      await until(
        () =>
            session.state == SupervisorState.failed || transport.closeObserved,
      );
      expect(session.error, '控制会话协议校验失败');
      expect(await session.stop(), false);
    });

    test('错launch不得进入native Core bind或HELLO', () async {
      transport.wrongLaunch = true;
      await expectLater(session.start(1), throwsA(isA<SupervisorFailure>()));
      expect(native.calls.contains('bindCoreChain'), false);
      expect(transport.frames.any((frame) => frame['type'] == 'hello'), false);
    });

    test('取消晚native worker不恢复旧epoch', () async {
      native.binding = Completer<Object?>();
      final start = session.start(1);
      final observed = expectLater(start, throwsA(isA<SupervisorFailure>()));
      await until(() => native.calls.contains('bindSupervisor'));
      final stopped = session.stop();
      native.binding!.complete({'handle': 'late-handle', 'generation': 1});
      await observed;
      await stopped;
      expect(session.state, isNot(SupervisorState.ready));
      expect(native.calls.contains('revokeLaunch'), true);
      expect(transport.frames.isEmpty, true);
    });

    test('取消晚Process仍关闭stdin并保留exit监听', () async {
      factory.delayedSpawn = Completer<SupervisorTransport>();
      final started = session.start(1);
      final observed = expectLater(started, throwsA(isA<SupervisorFailure>()));
      await until(() => factory.starts == 1);
      await session.stop();
      factory.delayedSpawn!.complete(transport);
      await observed;
      await until(() => transport.exited.isCompleted);
      expect(transport.closeObserved, true);
      expect(session.state, isNot(SupervisorState.ready));
      expect(native.calls.contains('revokeLaunch'), true);
      expect(
        native.calls.where((method) => method == 'bindSupervisor').length,
        1,
      );
    });

    test('取消晚reserve仍撤销native launch', () async {
      native.reservation = Completer<Object?>();
      final started = session.start(1);
      final observed = expectLater(started, throwsA(isA<SupervisorFailure>()));
      await until(() => native.calls.contains('reserveSupervisorLaunch'));
      await session.stop();
      native.reservation!.complete({
        'launch': launch,
        'generation': 1,
        'path': '/fixture/BettboxCoreSupervisor',
      });
      await observed;
      await until(() => native.calls.contains('revokeLaunch'));
      expect(factory.starts, 0);
      expect(session.state, isNot(SupervisorState.ready));
    });

    test('非canonical控制帧拒绝且不重同步', () async {
      factory.delayedSpawn = Completer<SupervisorTransport>();
      final started = session.start(1);
      final observed = expectLater(started, throwsA(isA<SupervisorFailure>()));
      await until(() => factory.starts == 1);
      factory.delayedSpawn!.complete(transport);
      await tick();
      final body = utf8.encode(
        '{"generation":1,"protocol":1,"type":"supervisor_ready"}',
      );
      final bytes = Uint8List(4 + body.length);
      ByteData.sublistView(bytes).setUint32(0, body.length, Endian.little);
      bytes.setRange(4, bytes.length, body);
      transport.stdout.add(bytes);
      await observed;
      await until(() => native.calls.contains('bindSupervisor'));
      // 撤销后的bind仅供停止出生ledger，不能获得helper/Core授权。
      expect(native.issuedHelperProofs, 0);
      expect(
        native.calls.indexOf('revokeLaunch'),
        lessThan(native.calls.indexOf('bindSupervisor')),
      );
      expect(native.calls.contains('bindCoreChain'), false);
      expect(transport.frames.any((frame) => frame['type'] == 'hello'), false);
    });

    test('core_ready与native链worker共享同一个Core预算', () async {
      native.delays['bindCoreChain'] = const Duration(milliseconds: 70);
      native.delays['recheckCoreChain'] = const Duration(milliseconds: 70);
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) {},
        startBudget: const Duration(milliseconds: 110),
      );
      await expectLater(session.start(1), throwsA(isA<SupervisorFailure>()));
      expect(transport.frames.any((frame) => frame['type'] == 'hello'), false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.state, isNot(SupervisorState.ready));
    });

    test('错generation和跳号credit失败关闭', () async {
      await session.start(1);
      await session.sendAction(id: 'a', method: 'getIsInit');
      transport.emit({
        'type': 'relay_credit',
        'protocol': 1,
        'generation': 2,
        'sequence': 1,
      });
      await until(() => transport.closeObserved);
      expect(await session.stop(), false);
    });

    test('flush迟到不能恢复credit或ready', () async {
      await session.start(1);
      transport.blockedWrite = Completer<void>();
      final sending = session.sendAction(id: 'a', method: 'getIsInit');
      final observed = expectLater(sending, throwsA(isA<SupervisorFailure>()));
      await until(() => transport.businessCount == 1);
      transport.credit(1);
      final stopped = session.stop();
      transport.blockedWrite!.complete();
      await observed;
      expect(await stopped, true);
      expect(session.state, SupervisorState.stopped);
    });

    test('异步结果回调不暂停credit读取', () async {
      final consumer = Completer<void>();
      session = SupervisorSession(
        native: native,
        factory: factory,
        onResult: (_) => consumer.future,
      );
      await session.start(1);
      await session.sendAction(id: 'a', method: 'getIsInit');
      final second = session.sendAction(id: 'b', method: 'getIsInit');
      transport.emit({
        'protocol': 1,
        'generation': 1,
        'result': {'id': 'a', 'method': 'getIsInit', 'data': true},
      });
      transport.credit(1);
      await second;
      expect(transport.businessCount, 2);
      consumer.complete();
      expect(await session.stop(), true);
    });
  });
}
