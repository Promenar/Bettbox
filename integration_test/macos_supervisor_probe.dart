import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:bett_box/clash/supervisor/supervisor_method_channel.dart';
import 'package:bett_box/clash/supervisor/supervisor_application.dart';
import 'package:bett_box/clash/supervisor/supervisor_session.dart';
import 'package:bett_box/clash/supervisor/supervisor_transport.dart';

import 'probe_contract.dart';

// 保留未知所有者的宿主、真实Session和公开子进程引用。
_ProbeHost? _retainedHost;

void main() {
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final host = _ProbeHost();
      _retainedHost = host;
      FlutterError.onError = (_) => host.cancel();
      PlatformDispatcher.instance.onError = (_, _) {
        host.cancel();
        return true;
      };
      host.watchCancellation();
      runApp(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.shrink(),
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(host.run());
      });
    },
    (_, _) {
      final host = _retainedHost;
      if (host != null) host.cancel();
    },
    zoneSpecification: ZoneSpecification(
      // Dart、Flutter及依赖的print不能回显原始错误或载荷。
      print: (_, _, _, _) {},
    ),
  );
}

class _Canceled implements Exception {
  const _Canceled();
}

class _ProbeFailure implements Exception {
  const _ProbeFailure();
}

class _ChildObservation {
  Process? process;
  Future<int>? exitObservation;
  int? observedExitCode;
  bool exitObserved = false;
  bool stdoutDrained = false;
  bool stderrDrained = false;
  bool complete = false;
  bool observationFailed = false;

  Future<void> observe() async {
    try {
      final child = await Process.start(
        '/usr/bin/true',
        const [],
        environment: const {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
        includeParentEnvironment: false,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      process = child;
      // 唯一一次取得exitCode；双管道并行排空，不解码、不缓存载荷。
      final exited = child.exitCode;
      exitObservation = exited;
      await Future.wait<void>([
        exited.then<void>((code) {
          exitObserved = true;
          observedExitCode = code;
        }),
        child.stdout.drain<void>().then((_) {
          stdoutDrained = true;
        }),
        child.stderr.drain<void>().then((_) {
          stderrDrained = true;
        }),
      ]);
      complete = true;
      if (observedExitCode != 0) throw const _ProbeFailure();
    } catch (_) {
      // 退出及EOF未全部确认时，错误不能证明没有遗留子进程。
      if (!complete) observationFailed = true;
      rethrow;
    }
  }

  bool get hasUnknownOwner =>
      !complete ||
      observationFailed ||
      !exitObserved ||
      !stdoutDrained ||
      !stderrDrained;
}

class _ProbeHost {
  _ProbeHost() {
    application = SupervisorApplication(
      buildSession: (result, revoked) => SupervisorSession(
        native: const MethodChannelSupervisorNative(),
        factory: ProcessSupervisorTransportFactory(),
        onResult: result,
        onRevoked: revoked,
      ),
      onEvent: (_) => throw const _ProbeFailure(),
    );
  }

  late final SupervisorApplication application;
  final _cancellation = Completer<void>();
  final _children = <_ChildObservation>[];
  StreamSubscription<List<int>>? _stdin;
  bool _canceled = false;
  bool _terminal = false;
  Timer? _retentionTimer;

  void watchCancellation() {
    try {
      _stdin ??= stdin.listen(
        (_) => cancel(),
        onDone: cancel,
        onError: (Object _) => cancel(),
      );
    } catch (_) {
      cancel();
    }
  }

  void cancel() {
    if (_terminal || _canceled) return;
    _canceled = true;
    _cancellation.complete();
    // 撤销即时执行，只有run负责输出终态；stop自身合并并发调用。
    unawaited(
      application.shutdown().then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<T> _observe<T>(Future<T> future, Duration budget) {
    return Future.any<T>([
      future.timeout(budget),
      _cancellation.future.then<T>((_) => throw const _Canceled()),
    ]);
  }

  void _checkActive() {
    if (_canceled) throw const _Canceled();
  }

  void _mark(String marker) => stdout.writeln(marker);

  Future<void> run() async {
    try {
      for (var generation = 1; generation <= 2; generation++) {
        _checkActive();
        await _observe(application.restart(), const Duration(seconds: 30));
        _checkActive();
        if (!application.isReady) {
          throw const _ProbeFailure();
        }
        _mark('BETTBOX_PROBE_READY_$generation');
        final wave = List.generate(16, (_) => _ChildObservation());
        _children.addAll(wave);
        // 16个启动立即并行；每个公开child有独立的15秒观察期限。
        final childrenDone = Future.wait<void>([
          for (final child in wave)
            child.observe().timeout(const Duration(seconds: 15)),
        ]);
        final response = application.request(method: 'getIsInit');
        final results = await _observe(
          Future.wait<Object?>([response, childrenDone]),
          const Duration(seconds: 20),
        );
        if (!acceptsProbeResult(results[0], generation)) {
          throw const _ProbeFailure();
        }
        _checkActive();
        if (!application.isReady ||
            wave.any((child) => child.hasUnknownOwner)) {
          throw const _ProbeFailure();
        }
        _mark('BETTBOX_PROBE_RESULT_$generation');
        final stopped = await application.shutdown();
        _checkActive();
        if (!stopped ||
            application.hasUnconfirmedOwner ||
            application.isReady) {
          throw const _ProbeFailure();
        }
        _mark('BETTBOX_PROBE_STOP_$generation');
      }
      _checkActive();
      if (_children.any((child) => child.hasUnknownOwner)) {
        throw const _ProbeFailure();
      }
      await _complete('BETTBOX_PROBE_PASS', 0);
    } catch (_) {
      await _fail();
    }
  }

  Future<void> _fail() async {
    if (_terminal) return;
    bool stopped = false;
    try {
      stopped = await application.shutdown();
    } catch (_) {}
    if (stopped &&
        !application.hasUnconfirmedOwner &&
        !_children.any((child) => child.hasUnknownOwner)) {
      await _complete('BETTBOX_PROBE_FAIL_CLEAN', 70);
      return;
    }
    _terminal = true;
    _mark('BETTBOX_PROBE_OWNER_UNKNOWN');
    // 有限观察期限结束不意味着退出。保留引擎与所有引用，禁止新代次。
    _retentionTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {});
  }

  Future<void> _complete(String marker, int code) async {
    if (_terminal) return;
    if (code == 0) _checkActive();
    // 终态提交与取消检查之间没有await，避免竞争输出两个终态。
    _terminal = true;
    _mark(marker);
    try {
      await stdout.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    exit(code);
  }
}
