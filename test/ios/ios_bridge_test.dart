import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/clash/ios.dart';
import 'package:bett_box/common/constant.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bettbox/ios/test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late IOSClash bridge;
  late Directory home;
  final setup = SetupParams(
    config: {},
    selectedMap: {},
    testUrl: 'https://example.org',
  );
  const state = CoreState(
    vpnProps: VpnProps(),
    onlyStatisticsProxy: false,
    currentProfileName: '测试',
  );
  Map<String, Object?> status(String value, {int? at, bool accepted = false}) =>
      {
        'status': value,
        'connected': value == 'connected' || value == 'reasserting',
        'transitioning': value == 'connecting' || value == 'disconnecting',
        'connectedAt': ?at,
        if (accepted) 'accepted': true,
      };

  setUp(() async {
    bridge = IOSClash(
      channel: channel,
      requestTimeout: const Duration(milliseconds: 100),
      transitionTimeout: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 1),
    );
    home = await Directory.systemTemp.createTemp('bettbox-ios-test-');
    for (final name in [
      mmdbFileName,
      geoSiteFileName,
      asnFileName,
      bundleMRSFileName,
    ]) {
      await File(p.join(home.path, name)).writeAsString('测试资源');
    }
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await bridge.destroy();
    await home.delete(recursive: true);
  });

  test('排队停止不会取消随后登记的启动意图', () async {
    final lock = Lock();
    final occupied = Completer<void>();
    final entered = Completer<void>();
    final hold = lock.synchronized(() async {
      entered.complete();
      await occupied.future;
    });
    await entered.future;
    var nativeStarts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'publishSnapshot') {
        return {
          'schemaVersion': 1,
          'revision': 'fixture',
          'manifestHash': 'a' * 64,
        };
      }
      if (call.method == 'startVpn') {
        nativeStarts++;
        return status('connected', at: 1);
      }
      return status('disconnected');
    });
    bridge.cancelPendingStart();
    final stop = lock.synchronized(() => bridge.stopVpn(cancelPending: false));
    final generation = bridge.beginPendingStart();
    final start = lock.synchronized(() async {
      final inputs = await IOSSnapshotInputs.collect(setup, home.path);
      await bridge.startSnapshot(inputs, state, {}, generation: generation);
    });
    occupied.complete();
    await Future.wait([hold, stop, start]);
    expect(nativeStarts, 1);
    expect(bridge.status.connected, true);
  });

  test('accepted 不产生 connectedAt，reasserting 保留真实系统时间', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => status('connecting', accepted: true),
    );
    final connecting = await bridge.refreshStatus();
    expect(connecting.connected, false);
    expect(connecting.connectedAt, null);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => status('reasserting', at: 1234567),
    );
    final connected = await bridge.refreshStatus();
    expect(connected.connected, true);
    expect(connected.status, 'reasserting');
    expect(connected.connectedAt?.millisecondsSinceEpoch, 1234567);
  });

  test('原生错误正文不会暴露到 Dart 错误', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(
        code: 'secret',
        message: 'password=虚构凭据 https://user:pass@example.org?token=秘密',
      ),
    );
    await expectLater(
      bridge.refreshStatus(),
      throwsA(
        predicate((Object error) {
          expect(error.toString(), isNot(contains('password')));
          expect(error.toString(), isNot(contains('example.org')));
          return error is IOSCoreException;
        }),
      ),
    );
  });

  test('preload 状态不可读取仍允许 UI 启动，不伪造已断开会话', () async {
    const events = EventChannel('bettbox/ios/test/events');
    messenger.setMockMethodCallHandler(
      const MethodChannel('bettbox/ios/test/events'),
      (_) async => null,
    );
    bridge = IOSClash(channel: channel, events: events);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'vpn'),
    );
    expect(await bridge.preload(), true);
    expect(bridge.status.status, 'invalid');
    expect(bridge.status.connected, false);
    // 后续重新读取继续失败，不能把初始 invalid 当作成功读取系统状态。
    await expectLater(bridge.refreshStatus(), throwsA(isA<IOSCoreException>()));
    await bridge.destroy();
    messenger.setMockMethodCallHandler(
      const MethodChannel('bettbox/ios/test/events'),
      null,
    );
  });

  test('显式 Simulator 能力不发布或启动 VPN', () async {
    var otherCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return {...status('invalid'), 'vpnSupported': false};
      }
      otherCalls++;
      throw StateError('不应启动');
    });
    await expectLater(
      bridge.startSnapshot(
        await IOSSnapshotInputs.collect(setup, home.path),
        state,
        {},
        generation: bridge.beginPendingStart(),
      ),
      throwsA(isA<IOSCoreException>()),
    );
    expect(bridge.status.vpnSupported, false);
    expect(otherCalls, 0);
  });

  test('NE 状态事件驱动状态，accepted 不能覆盖事件语义', () async {
    const eventName = 'bettbox/ios/test/status-events';
    const eventMethod = MethodChannel(eventName);
    messenger.setMockMethodCallHandler(eventMethod, (_) async => null);
    bridge = IOSClash(channel: channel, events: const EventChannel(eventName));
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => status('disconnected'),
    );
    await bridge.preload();
    final observed = bridge.statuses.first;
    await messenger.handlePlatformMessage(
      eventName,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'kind': 'vpnStatus',
        ...status('connected', at: 1234567, accepted: true),
      }),
      (_) {},
    );
    expect((await observed).connectedAt?.millisecondsSinceEpoch, 1234567);
    expect(bridge.status.connected, true);
    await bridge.destroy();
    messenger.setMockMethodCallHandler(eventMethod, null);
  });

  test('核心方法保持字符串编码、身份绑定和 30 秒上限', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'coreAction');
      final args = call.arguments as Map;
      expect(args['transport'], 'auto');
      expect(args['timeoutMs'], 30000);
      final action = jsonDecode(args['action'] as String) as Map;
      expect(action['data'], '配置正文');
      return jsonEncode({
        'id': action['id'],
        'method': action['method'],
        'code': 0,
        'data': '',
      });
    });
    expect(
      await bridge.invoke<String>(
        method: ActionMethod.validateConfig,
        data: '配置正文',
        timeout: const Duration(seconds: 60),
      ),
      '',
    );
  });

  test('校验完成但非空诊断只返回固定类别，不泄露 URL 或对象名', () async {
    const secretDiagnostic =
        'password=公开虚构凭据 https://user:pass@example.org?token=虚构秘密';
    String diagnostic = secretDiagnostic;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final action = jsonDecode(args['action'] as String) as Map;
      return jsonEncode({
        'id': action['id'],
        'method': action['method'],
        'code': 0,
        'data': diagnostic,
      });
    });
    final category = await bridge.invoke<String>(
      method: ActionMethod.validateConfig,
      data: '测试配置',
    );
    expect(category, '配置校验失败');
    // Profile.saveFile 会 throw/log 诊断；传播到该路径的字符串必须已被分类。
    try {
      throw category;
    } catch (error) {
      expect(error.toString(), isNot(contains(secretDiagnostic)));
      expect(error.toString(), isNot(contains('example.org')));
      expect(error.toString(), isNot(contains('password')));
    }
    diagnostic = 'duplicate name: 私有对象名 $secretDiagnostic';
    final duplicate = await bridge.invoke<String>(
      method: ActionMethod.validateConfig,
      data: '测试配置',
    );
    expect(duplicate, 'duplicate name');
    expect(duplicate.contains('duplicate name'), true);
    expect(duplicate, isNot(contains('私有对象名')));
    expect(duplicate, isNot(contains('example.org')));
    // 其它核心成功结果维持原协议，不采用配置诊断映射。
    expect(
      await bridge.invoke<String>(method: ActionMethod.decryptAgeConfig),
      diagnostic,
    );
  });

  test('拒绝错配响应及含秘密的非法 JSON', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => '{token=虚构秘密');
    await expectLater(
      bridge.isInit,
      throwsA(
        predicate(
          (Object error) =>
              error is IOSCoreException && !error.toString().contains('token'),
        ),
      ),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => jsonEncode({
        'id': '其他请求',
        'method': 'getIsInit',
        'code': 0,
        'data': true,
      }),
    );
    await expectLater(bridge.isInit, throwsA(isA<IOSCoreException>()));
  });

  test('桌面 Listener 与 crash 不调用原生', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (_) async {
      called = true;
      return true;
    });
    await expectLater(bridge.startListener(), throwsA(isA<IOSCoreException>()));
    await expectLater(bridge.stopListener(), throwsA(isA<IOSCoreException>()));
    await expectLater(bridge.crash(), throwsA(isA<IOSCoreException>()));
    expect(called, false);
  });

  test('请求严格串行，超时的未返回请求不释放原生在途槽', () async {
    bridge = IOSClash(
      channel: channel,
      requestTimeout: const Duration(milliseconds: 10),
    );
    final held = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      if (calls == 1) return held.future;
      return status('disconnected');
    });
    final first = bridge.refreshStatus();
    final second = bridge.refreshStatus();
    await expectLater(first, throwsA(isA<IOSCoreException>()));
    await expectLater(second, throwsA(isA<IOSCoreException>()));
    expect(calls, 1);
    held.complete(status('disconnected'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, 2);
  });

  test('HTTP 首次缺缓存仅声明安全目标，file 缺文件拒绝', () async {
    final config = {
      'proxy-providers': {
        '测试': {
          'type': 'http',
          'url': 'https://example.org/provider?token=虚构值',
          'path': p.join(home.path, 'cache', 'missing.yaml'),
        },
      },
    };
    final inputs = await IOSSnapshotInputs.collect(
      setup.copyWith(config: config),
      home.path,
    );
    expect(inputs.resources.length, 4);
    final provider =
        (inputs.setup.config['proxy-providers'] as Map)['测试'] as Map;
    expect(IOSSnapshotInputs.safePath(provider['path'] as String), true);
    expect(provider['url'], config['proxy-providers']!['测试']!['url']);
    config['proxy-providers']!['测试']!['type'] = 'file';
    await expectLater(
      IOSSnapshotInputs.collect(setup.copyWith(config: config), home.path),
      throwsA(isA<IOSCoreException>()),
    );
  });

  test('实际 provider 缓存与 Geo 显式列入清单', () async {
    final cache = File(p.join(home.path, 'provider.yaml'));
    await cache.writeAsString('proxies: []');
    final inputs = await IOSSnapshotInputs.collect(
      setup.copyWith(
        config: {
          'rule-providers': {
            '规则': {'type': 'file', 'path': cache.path},
          },
        },
      ),
      home.path,
    );
    expect(inputs.resources.length, 5);
    expect(
      inputs.resources.last['sourcePath'],
      await cache.resolveSymbolicLinks(),
    );
    expect(inputs.resources.last['path'], startsWith('providers/'));
    expect(
      inputs.resources.any((resource) => resource['path'] == geoSiteFileName),
      true,
    );
  });

  test('声明私有目录别名与规范路径均映射同一受控缓存', () async {
    final alias = Link(p.join(home.path, '私有目录别名'));
    final canonical = await home.resolveSymbolicLinks();
    await alias.create(canonical);
    final cache = File(p.join(canonical, 'provider.yaml'));
    await cache.writeAsString('proxies: []');
    for (final source in [p.join(alias.path, 'provider.yaml'), cache.path]) {
      final inputs = await IOSSnapshotInputs.collect(
        setup.copyWith(
          config: {
            'proxy-providers': {
              '缓存': {'type': 'file', 'path': source},
            },
          },
        ),
        alias.path,
      );
      expect(
        inputs.resources.last['sourcePath'],
        await cache.resolveSymbolicLinks(),
      );
      expect(inputs.resources.length, 5);
    }
    final missing = await IOSSnapshotInputs.collect(
      setup.copyWith(
        config: {
          'proxy-providers': {
            '下载': {
              'type': 'http',
              'path': p.join(alias.path, 'cache', 'missing.yaml'),
            },
          },
        },
      ),
      alias.path,
    );
    expect(missing.resources.length, 4);
    expect(
      IOSSnapshotInputs.safePath(
        (missing.setup.config['proxy-providers'] as Map)['下载']['path']
            as String,
      ),
      true,
    );
    // 指向同一私有目录的外部别名也不能扩大调用方声明的词法边界。
    final external = await Directory.systemTemp.createTemp(
      'bettbox-ios-external-alias-',
    );
    try {
      final externalAlias = Link(p.join(external.path, 'private-home'));
      await externalAlias.create(canonical);
      await expectLater(
        IOSSnapshotInputs.collect(
          setup.copyWith(
            config: {
              'proxy-providers': {
                '外部别名': {
                  'type': 'file',
                  'path': p.join(externalAlias.path, 'provider.yaml'),
                },
              },
            },
          ),
          alias.path,
        ),
        throwsA(isA<IOSCoreException>()),
      );
    } finally {
      await external.delete(recursive: true);
    }
  });

  test('资源缺失、路径穿越与符号链接逃逸拒绝', () async {
    for (final path in [
      '../外部.yaml',
      'cache//配置.yaml',
      '/不属于容器/配置.yaml',
      '${home.path}/cache/../配置.yaml',
      '${home.path}/cache//配置.yaml',
    ]) {
      await expectLater(
        IOSSnapshotInputs.collect(
          setup.copyWith(
            config: {
              'proxy-providers': {
                '测试': {'type': 'http', 'path': path},
              },
            },
          ),
          home.path,
        ),
        throwsA(isA<IOSCoreException>()),
      );
    }
    final outside = await Directory.systemTemp.createTemp(
      'bettbox-ios-outside-',
    );
    try {
      await Link(p.join(home.path, 'escape')).create(outside.path);
      await expectLater(
        IOSSnapshotInputs.collect(
          setup.copyWith(
            config: {
              'proxy-providers': {
                '测试': {'type': 'http', 'path': 'escape/missing.yaml'},
              },
            },
          ),
          home.path,
        ),
        throwsA(isA<IOSCoreException>()),
      );
    } finally {
      await outside.delete(recursive: true);
    }
    await File(p.join(home.path, geoSiteFileName)).delete();
    await expectLater(
      IOSSnapshotInputs.collect(setup, home.path),
      throwsA(isA<IOSCoreException>()),
    );
  });

  test('startVpn 只携带发布返回的 revision/hash，等待真实连接', () async {
    var started = false;
    var statusReads = 0;
    final hash = List.filled(64, 'a').join();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getStatus':
          statusReads++;
          return status(
            started && statusReads > 2
                ? 'connected'
                : started
                ? 'connecting'
                : 'disconnected',
            at: started && statusReads > 2 ? 1234567 : null,
          );
        case 'publishSnapshot':
          return {'schemaVersion': 1, 'revision': '绑定版本', 'manifestHash': hash};
        case 'startVpn':
          expect(call.arguments, {'revision': '绑定版本', 'manifestHash': hash});
          started = true;
          return status('connecting', accepted: true);
      }
      throw StateError('未知方法');
    });
    await bridge.startSnapshot(
      await IOSSnapshotInputs.collect(setup, home.path),
      state,
      {},
      generation: bridge.beginPendingStart(),
    );
    expect(statusReads, greaterThan(2));
    expect(bridge.status.connectedAt?.millisecondsSinceEpoch, 1234567);
  });

  test('进入预检前取消不会执行预检、资源收集或原生启动', () async {
    var nativeCalls = 0;
    var preflightCalls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      nativeCalls++;
      return status('disconnected');
    });
    final inputs = await IOSSnapshotInputs.collect(setup, home.path);
    final generation = bridge.beginPendingStart();
    bridge.cancelPendingStart();
    await expectLater(
      bridge.startStage(generation, () async {
        preflightCalls++;
        return true;
      }),
      throwsA(isA<IOSCoreException>()),
    );
    await expectLater(
      bridge.startSnapshot(inputs, state, {}, generation: generation),
      throwsA(isA<IOSCoreException>()),
    );
    expect(preflightCalls, 0);
    expect(nativeCalls, 0);
  });

  test('预检等待时取消不能在资源阶段重新取得启动代次', () async {
    final entered = Completer<void>();
    final preflight = Completer<bool>();
    var collections = 0;
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      nativeCalls++;
      return status('disconnected');
    });
    final generation = bridge.beginPendingStart();
    final pending = () async {
      await bridge.startStage(generation, () {
        entered.complete();
        return preflight.future;
      });
      final inputs = await bridge.startStage(generation, () {
        collections++;
        return IOSSnapshotInputs.collect(setup, home.path);
      });
      await bridge.startSnapshot(inputs, state, {}, generation: generation);
    }();
    final rejected = expectLater(pending, throwsA(isA<IOSCoreException>()));
    await entered.future;
    bridge.cancelPendingStart();
    preflight.complete(true);
    await rejected;
    expect(collections, 0);
    expect(nativeCalls, 0);
  });

  test('资源收集等待时取消不会发布快照或启动系统 VPN', () async {
    final entered = Completer<void>();
    final resources = Completer<IOSSnapshotInputs>();
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      nativeCalls++;
      return status('disconnected');
    });
    final inputs = await IOSSnapshotInputs.collect(setup, home.path);
    final generation = bridge.beginPendingStart();
    final pending = () async {
      final collected = await bridge.startStage(generation, () {
        entered.complete();
        return resources.future;
      });
      await bridge.startSnapshot(collected, state, {}, generation: generation);
    }();
    final rejected = expectLater(pending, throwsA(isA<IOSCoreException>()));
    await entered.future;
    bridge.cancelPendingStart();
    resources.complete(inputs);
    await rejected;
    expect(nativeCalls, 0);
  });

  test('用户停止 epoch 不被重启内部 stop 的原生代次覆盖', () async {
    final intent = IOSUserStopIntent();
    final stopEntered = Completer<void>();
    final stopped = Completer<Map<String, Object?>>();
    var obtainedNewGeneration = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'stopVpn') throw StateError('不应执行其他原生操作');
      stopEntered.complete();
      return stopped.future;
    });
    final userEpoch = intent.capture();
    final pending = () async {
      await bridge.stopVpn();
      intent.check(userEpoch);
      intent.ensureStartAllowed();
      obtainedNewGeneration = true;
      bridge.beginPendingStart();
    }();
    final rejected = expectLater(pending, throwsA(isA<IOSCoreException>()));
    await stopEntered.future;
    intent.cancel();
    bridge.cancelPendingStart();
    stopped.complete(status('disconnected'));
    await rejected;
    expect(obtainedNewGeneration, false);

    // 内部 stop 自身只推进原生代次，不改变用户停止 epoch。
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => status('disconnected'),
    );
    intent.requestStart();
    final epochWithoutUserStop = intent.capture();
    await bridge.stopVpn();
    intent.check(epochWithoutUserStop);
    intent.ensureStartAllowed();
    final generation = bridge.beginPendingStart();
    expect(await bridge.startStage(generation, () async => true), true);
  });

  test('先排队的用户停止不会被后来捕获的重启 epoch 遗忘', () async {
    final intent = IOSUserStopIntent();
    intent.cancel();
    final capturedAfterStop = intent.capture();
    intent.check(capturedAfterStop);
    expect(intent.ensureStartAllowed, throwsA(isA<IOSCoreException>()));
    intent.requestStart();
    expect(intent.ensureStartAllowed, returnsNormally);
  });

  test('重启内部原生停止失败不会取得新启动代次', () async {
    var obtainedNewGeneration = false;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'stop', message: '公开虚构原生诊断');
    });
    final previous = bridge.beginPendingStart();
    final pending = () async {
      await bridge.stopVpn();
      obtainedNewGeneration = true;
      bridge.beginPendingStart();
    }();
    await expectLater(pending, throwsA(isA<IOSCoreException>()));
    expect(obtainedNewGeneration, false);
    expect(
      () => bridge.checkPendingStart(previous),
      throwsA(isA<IOSCoreException>()),
    );
  });

  test('发布时取消不发 startVpn，发布错误不报告连接', () async {
    var starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') return status('disconnected');
      if (call.method == 'publishSnapshot') {
        bridge.cancelPendingStart();
        return {
          'schemaVersion': 1,
          'revision': '取消版本',
          'manifestHash': List.filled(64, 'a').join(),
        };
      }
      starts++;
      return status('connected');
    });
    final inputs = await IOSSnapshotInputs.collect(setup, home.path);
    await expectLater(
      bridge.startSnapshot(
        inputs,
        state,
        {},
        generation: bridge.beginPendingStart(),
      ),
      throwsA(isA<IOSCoreException>()),
    );
    expect(starts, 0);
    expect(bridge.status.connected, false);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') return status('disconnected');
      throw PlatformException(code: 'snapshot', message: '虚构配置秘密');
    });
    await expectLater(
      bridge.startSnapshot(
        inputs,
        state,
        {},
        generation: bridge.beginPendingStart(),
      ),
      throwsA(isA<IOSCoreException>()),
    );
    expect(bridge.status.connected, false);
  });

  test('下载或系统启动失败、重复停止维持真实断开状态', () async {
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'publishSnapshot') {
        return {
          'schemaVersion': 1,
          'revision': '版本',
          'manifestHash': List.filled(64, 'a').join(),
        };
      }
      if (call.method == 'startVpn') {
        return status('connecting', accepted: true);
      }
      if (call.method == 'stopVpn') {
        return status('disconnected', accepted: true);
      }
      reads++;
      return status('disconnected');
    });
    await expectLater(
      bridge.startSnapshot(
        await IOSSnapshotInputs.collect(setup, home.path),
        state,
        {},
        generation: bridge.beginPendingStart(),
      ),
      throwsA(isA<IOSCoreException>()),
    );
    expect(reads, greaterThan(1));
    expect(bridge.status.connected, false);
    await bridge.stopVpn();
    await bridge.stopVpn();
    expect(bridge.status.connectedAt, null);
  });
}
