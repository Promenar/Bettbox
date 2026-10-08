import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_codec.dart';
import 'package:bett_box/clash/supervisor/supervisor_rpc.dart';
import 'package:bett_box/clash/supervisor/supervisor_events.dart';

Map<String, Object?> reply(String id, String method, Object? data) => {
  'id': id,
  'method': method,
  'data': data,
  'code': 0,
  'Port': 0,
};

class Harness {
  Harness({
    SupervisorRpcSender? sender,
    FutureOr<void> Function(Map<String, Object?>)? event,
  }) {
    rpc = SupervisorRpc(
      generation: 2,
      send:
          sender ??
          (id, method, data) async {
            sent.add((id, method));
          },
      onFatal: () {
        fatal++;
      },
      onEvent: (message) {
        final task = event == null ? null : event(message);
        if (event == null) events++;
        return SupervisorEventBatch(task is Future<void> ? [task] : const []);
      },
    );
  }
  late final SupervisorRpc rpc;
  final sent = <(String, String)>[];
  int fatal = 0;
  int events = 0;
}

void main() {
  test('异步事件最多32个，关闭保留未知消费者直至实际结束', () async {
    final pending = Completer<void>();
    final h = Harness(event: (_) => pending.future);
    for (var i = 0; i < 32; i++) {
      h.rpc.receive(
        reply('', 'message', <String, dynamic>{
          'type': 'loaded',
          'data': 'public',
        }),
      );
    }
    expect(h.rpc.hasUnconfirmedConsumers, true);
    expect(h.fatal, 0);
    h.rpc.receive(
      reply('', 'message', <String, dynamic>{
        'type': 'loaded',
        'data': 'public',
      }),
    );
    expect(h.fatal, 1);
    expect(h.rpc.hasUnconfirmedConsumers, true);
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.rpc.hasUnconfirmedConsumers, false);
  });
  test('异步事件异常被观察并撤销整代', () async {
    final h = Harness(
      event: (_) async {
        throw StateError('公开异步事件错误');
      },
    );
    h.rpc.receive(
      reply('', 'message', <String, dynamic>{
        'type': 'loaded',
        'data': 'public',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(h.fatal, 1);
    expect(h.rpc.hasUnconfirmedConsumers, false);
  });

  for (final cause in ['timeout', 'close']) {
    test('早回包且sender挂起时$cause必须结束请求并释放预算', () async {
      final sending = Completer<void>();
      late Harness h;
      h = Harness(
        sender: (id, method, data) {
          h.rpc.receive(reply(id, method, '公开结果'));
          return sending.future;
        },
      );
      final request = h.rpc.request(
        method: 'getIsInit',
        timeout: const Duration(milliseconds: 10),
      );
      unawaited(request.then<void>((_) {}, onError: (Object _) {}));
      if (cause == 'close') h.rpc.close();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      try {
        expect(h.rpc.isClosed, true);
        expect(h.rpc.pendingCount, 0);
        expect(h.rpc.retainedResultBytes, 0);
        expect(h.fatal, cause == 'timeout' ? 1 : 0);
      } finally {
        h.rpc.close();
        sending.complete();
      }
    });
  }

  test('有效回包不能早于发送确认交付，迟到发送失败撤销整代', () async {
    final sending = Completer<void>();
    late Harness h;
    h = Harness(
      sender: (id, method, data) {
        h.rpc.receive(reply(id, method, false));
        return sending.future;
      },
    );
    var delivered = false;
    final request = h.rpc.request(method: 'getIsInit').then((value) {
      delivered = true;
      return value;
    });
    unawaited(request.then<void>((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(Duration.zero);
    try {
      expect(delivered, false);
    } finally {
      sending.completeError(StateError('公开迟到发送错误'));
    }
    await expectLater(request, throwsA(isA<SupervisorFailure>()));
    expect(h.fatal, 1);
    expect(h.rpc.isClosed, true);
  });

  test('同步回包匹配代次ID并及时释放请求和结果预算', () async {
    late Harness h;
    h = Harness(
      sender: (id, method, data) async {
        expect(id, 'g2-r1');
        h.rpc.receive(reply(id, method, false));
      },
    );
    expect((await h.rpc.request(method: 'getIsInit'))['data'], false);
    expect(h.rpc.pendingCount, 0);
    expect(h.rpc.retainedResultBytes, 0);
    expect(h.fatal, 0);
    h.rpc.close();
  });

  test('八个在途请求拒绝第九个且不撤销已有请求', () async {
    final h = Harness();
    final pending = [
      for (var i = 0; i < 8; i++) h.rpc.request(method: 'getIsInit'),
    ];
    for (final future in pending) {
      unawaited(future.then<void>((_) {}, onError: (Object _) {}));
    }
    await expectLater(
      h.rpc.request(method: 'getIsInit'),
      throwsA(isA<SupervisorFailure>()),
    );
    expect(h.rpc.pendingCount, 8);
    expect(h.fatal, 0);
    for (final (id, method) in h.sent) {
      h.rpc.receive(reply(id, method, false));
    }
    await Future.wait(pending);
    expect(h.rpc.pendingCount, 0);
    h.rpc.close();
  });

  test('超时撤销整代并取消其它请求，不释放后允许重发', () async {
    final h = Harness();
    final first = h.rpc.request(
      method: 'getIsInit',
      timeout: const Duration(milliseconds: 10),
    );
    final second = h.rpc.request(method: 'getIsInit');
    final expectations = [
      expectLater(first, throwsA(isA<TimeoutException>())),
      expectLater(second, throwsA(isA<TimeoutException>())),
    ];
    await Future.wait(expectations);
    expect(h.fatal, 1);
    expect(h.rpc.isClosed, true);
    expect(h.rpc.pendingCount, 0);
    await expectLater(
      h.rpc.request(method: 'getIsInit'),
      throwsA(isA<SupervisorFailure>()),
    );
  });

  test('发送异常不泄漏原始信息并撤销所有请求', () async {
    final h = Harness(
      sender: (id, method, data) async {
        throw StateError('公开错误夹具');
      },
    );
    await expectLater(
      h.rpc.request(method: 'getIsInit'),
      throwsA(isA<SupervisorFailure>()),
    );
    expect(h.fatal, 1);
    expect(h.rpc.pendingCount, 0);
  });

  test('方法错配、额外键、重复回包、未知ID均撤销，不交付已完成污染结果', () async {
    for (final scenario in ['method', 'extra', 'duplicate', 'unknown']) {
      final h = Harness();
      final future = h.rpc.request(method: 'getIsInit');
      final expectation = expectLater(
        future,
        throwsA(isA<SupervisorFailure>()),
      );
      final value = reply('g2-r1', 'getIsInit', false);
      if (scenario == 'method') value['method'] = 'getTraffic';
      if (scenario == 'extra') value['extra'] = 0;
      if (scenario == 'unknown') value['id'] = 'g1-r1';
      h.rpc.receive(value);
      if (scenario == 'duplicate') h.rpc.receive(value);
      await expectation;
      expect(h.fatal, 1);
      expect(h.rpc.pendingCount, 0);
    }
  });

  test('两份大结果不能越过16MiB交付预算', () async {
    final h = Harness();
    final futures = [
      h.rpc.request(method: 'getConfig'),
      h.rpc.request(method: 'getConfig'),
    ];
    final waits = [
      for (final f in futures)
        expectLater(f, throwsA(isA<SupervisorFailure>())),
    ];
    final data = 'x' * (9 * 1024 * 1024);
    h.rpc.receive(reply('g2-r1', 'getConfig', data));
    expect(h.rpc.retainedResultBytes, greaterThan(9 * 1024 * 1024));
    h.rpc.receive(reply('g2-r2', 'getConfig', data));
    await Future.wait(waits);
    expect(h.fatal, 1);
    expect(h.rpc.retainedResultBytes, 0);
  });

  test('事件同步消费，超限或监听器错误只撤销一次', () {
    final h = Harness();
    h.rpc.receive(
      reply('', 'message', <String, dynamic>{
        'type': 'loaded',
        'data': 'public',
      }),
    );
    expect(h.events, 1);
    expect(h.rpc.pendingCount, 0);
    h.rpc.receive(
      reply('', 'message', <String, dynamic>{'data': 'x' * (1024 * 1024)}),
    );
    expect(h.fatal, 1);
    expect(h.events, 1);
    h.rpc.receive(reply('', 'message', {}));
    expect(h.fatal, 1);
    final throwing = Harness(
      event: (_) {
        throw StateError('公开监听错误');
      },
    );
    throwing.rpc.receive(reply('', 'message', <String, dynamic>{}));
    expect(throwing.fatal, 1);
  });

  test('正常关闭立即拒绝pending并丢弃迟到回包，不回调fatal', () async {
    final h = Harness();
    final future = h.rpc.request(method: 'getIsInit');
    final expectation = expectLater(future, throwsA(isA<SupervisorFailure>()));
    h.rpc.close();
    h.rpc.receive(reply('g2-r1', 'getIsInit', false));
    await expectation;
    expect(h.fatal, 0);
    expect(h.rpc.pendingCount, 0);
  });
}
