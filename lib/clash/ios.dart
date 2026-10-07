import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../common/constant.dart';
import '../enum/enum.dart';
import '../models/models.dart';
import 'interface.dart';
import 'message.dart';

/// 错误只携带固定类别，原生错误正文可能包含配置或凭据。
class IOSCoreException implements Exception {
  final String category;
  const IOSCoreException(this.category);
  @override
  String toString() => 'iOS 核心操作失败：$category';
}

/// 用户停止意图独立于原生停止代次；内部重启不能清除用户取消。
class IOSUserStopIntent {
  int _epoch = 0;
  bool _stopRequested = false;
  int capture() => _epoch;
  void requestStart() => _stopRequested = false;
  void cancel() {
    _stopRequested = true;
    _epoch++;
  }

  void ensureStartAllowed() {
    if (_stopRequested) throw const IOSCoreException('启动已取消');
  }

  void check(int epoch) {
    if (epoch != _epoch) throw const IOSCoreException('启动已取消');
  }
}

class IOSVpnStatus {
  final String status;
  final DateTime? connectedAt;
  final bool vpnSupported;
  const IOSVpnStatus(this.status, [this.connectedAt, this.vpnSupported = true]);
  bool get connected => status == 'connected' || status == 'reasserting';
  bool get transitioning => status == 'connecting' || status == 'disconnecting';

  factory IOSVpnStatus.fromMap(Map<dynamic, dynamic> value) {
    final status = value['status'];
    if (!const {
      'invalid',
      'disconnected',
      'connecting',
      'connected',
      'reasserting',
      'disconnecting',
    }.contains(status)) {
      throw const IOSCoreException('系统状态无效');
    }
    final at = value['connectedAt'];
    return IOSVpnStatus(
      status as String,
      at is int && at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      value['vpnSupported'] != false,
    );
  }
}

/// 快照资源只来自指定私有目录；HTTP 首次无缓存不声明资源存在。
class IOSSnapshotInputs {
  final SetupParams setup;
  final List<Map<String, String>> resources;
  IOSSnapshotInputs(this.setup, this.resources);

  static bool safePath(String path) =>
      path.isNotEmpty &&
      !p.isAbsolute(path) &&
      !path.contains('\\') &&
      path
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');

  static Future<IOSSnapshotInputs> collect(
    SetupParams setup,
    String home,
  ) async {
    final declaredHome = p.normalize(p.absolute(home));
    final root = await Directory(home).resolveSymbolicLinks();
    final config = jsonDecode(jsonEncode(setup.config)) as Map<String, dynamic>;
    final resources = <Map<String, String>>[];
    final paths = <String>{};
    var total = 0;
    Future<bool> add(
      String source,
      String target, {
      bool required = true,
    }) async {
      if (!safePath(target)) throw const IOSCoreException('资源路径无效');
      // /var 与 /private/var 等容器别名先守住声明目录的词法边界，
      // 再把同一受控相对路径放到规范目录中；不接受任意外部别名。
      if (!p.isAbsolute(source) ||
          source.contains('\\') ||
          source
              .split('/')
              .skip(1)
              .any((part) => part.isEmpty || part == '.' || part == '..')) {
        throw const IOSCoreException('资源路径无效');
      }
      final lexical = p.normalize(source);
      final String relative;
      if (p.isWithin(declaredHome, lexical)) {
        relative = p.relative(lexical, from: declaredHome);
      } else if (p.isWithin(root, lexical)) {
        relative = p.relative(lexical, from: root);
      } else {
        throw const IOSCoreException('资源越出私有目录');
      }
      if (!safePath(relative)) throw const IOSCoreException('资源路径无效');
      final normalized = p.join(root, relative);
      if (!await File(normalized).exists()) {
        // 缺缓存也核验最近的现有父目录，防止符号链接逃逸。
        var parent = p.dirname(normalized);
        while (await FileSystemEntity.type(parent, followLinks: false) ==
                FileSystemEntityType.notFound &&
            parent != p.dirname(parent)) {
          parent = p.dirname(parent);
        }
        final String resolvedParent;
        try {
          resolvedParent = await Directory(parent).resolveSymbolicLinks();
        } on FileSystemException {
          throw const IOSCoreException('资源父目录无效');
        }
        if (resolvedParent != root && !p.isWithin(root, resolvedParent)) {
          throw const IOSCoreException('资源符号链接越界');
        }
        if (required) throw const IOSCoreException('必要资源缺失');
        return false;
      }
      final resolved = await File(normalized).resolveSymbolicLinks();
      if (!p.isWithin(root, resolved)) throw const IOSCoreException('资源符号链接越界');
      final stat = await File(resolved).stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > 64 * 1024 * 1024) {
        throw const IOSCoreException('资源类型或大小无效');
      }
      if (paths.add(target)) {
        total += stat.size;
        if (paths.length > 512 || total > 256 * 1024 * 1024) {
          throw const IOSCoreException('资源预算超限');
        }
        resources.add({'path': target, 'sourcePath': resolved});
      }
      return true;
    }

    for (final name in [
      mmdbFileName,
      geoSiteFileName,
      asnFileName,
      bundleMRSFileName,
    ]) {
      await add(p.join(root, name), name);
    }
    for (final key in ['proxy-providers', 'rule-providers']) {
      final providers = config[key];
      if (providers is! Map) continue;
      for (final entry in providers.entries) {
        final provider = entry.value;
        if (provider is! Map || provider['type'] == 'inline') continue;
        final path = provider['path'];
        if (path is! String || path.isEmpty) {
          throw const IOSCoreException('provider 路径缺失');
        }
        if (!p.isAbsolute(path) && !safePath(path)) {
          throw const IOSCoreException('provider 路径无效');
        }
        final source = p.isAbsolute(path) ? path : p.join(root, path);
        final target =
            'providers/${sha256.convert(utf8.encode('$key/${entry.key}'))}.cache';
        await add(source, target, required: provider['type'] != 'http');
        provider['path'] = target;
      }
    }
    return IOSSnapshotInputs(setup.copyWith(config: config), resources);
  }
}

class IOSClash extends ClashHandlerInterface {
  final MethodChannel channel;
  final EventChannel events;
  final Duration requestTimeout;
  final Duration transitionTimeout;
  final Duration pollInterval;
  final _statuses = StreamController<IOSVpnStatus>.broadcast();
  StreamSubscription<dynamic>? _events;
  Future<void> _tail = Future.value();
  int _pending = 0;
  int _id = 0;
  int _startGeneration = 0;
  IOSVpnStatus status = const IOSVpnStatus('invalid');
  Stream<IOSVpnStatus> get statuses => _statuses.stream;

  IOSClash({
    this.channel = const MethodChannel('bettbox/ios'),
    this.events = const EventChannel('bettbox/ios/events'),
    this.requestTimeout = const Duration(seconds: 33),
    this.transitionTimeout = const Duration(seconds: 50),
    this.pollInterval = const Duration(milliseconds: 250),
  });

  Future<T> _call<T>(
    String method, [
    Object? arguments,
    void Function()? beforeInvoke,
  ]) {
    if (_pending >= 8) return Future.error(const IOSCoreException('请求队列已满'));
    _pending++;
    final raw = _tail.then((_) async {
      try {
        beforeInvoke?.call();
        final result = await channel.invokeMethod<T>(method, arguments);
        if (result == null) throw const IOSCoreException('原生响应缺失');
        return result;
      } on PlatformException {
        throw const IOSCoreException('原生请求失败');
      } on MissingPluginException {
        throw const IOSCoreException('原生桥不可用');
      }
    });
    // 超时不会释放在途请求；迟到的原生调用结束前不运行后续请求。
    _tail = raw
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending--);
    return raw.timeout(
      requestTimeout,
      onTimeout: () => throw const IOSCoreException('请求超时'),
    );
  }

  void _acceptStatus(Map<dynamic, dynamic> value) {
    status = IOSVpnStatus.fromMap(value);
    _statuses.add(status);
  }

  @override
  Future<bool> preload() async {
    _events ??= events.receiveBroadcastStream().listen((event) {
      try {
        if (event is! Map) return;
        if (event['kind'] == 'vpnStatus') {
          _acceptStatus(event);
        } else if (event['kind'] == 'coreMessage' && event['data'] is String) {
          final result = ActionResult.fromJson(
            jsonDecode(event['data'] as String),
          );
          final message = result.data;
          // 核心日志和请求事件可能包含 URL、配置或凭据，不转发到日志模型。
          if (result.method == ActionMethod.message &&
              message is Map &&
              (message['type'] == 'delay' || message['type'] == 'loaded')) {
            clashMessage.controller.add(Map<String, Object?>.from(message));
          }
        }
      } catch (_) {
        /* 丢弃无效事件，不输出原始消息。 */
      }
    }, onError: (Object _) {});
    // 首次系统状态读取失败不阻断 UI，后续核心调用仍须重新核验状态。
    try {
      await refreshStatus();
    } on IOSCoreException {
      // UI 可以启动，后续核心操作仍须实际读取系统状态。
    }
    return true;
  }

  Future<IOSVpnStatus> refreshStatus() async {
    _acceptStatus(await _call<Map>('getStatus'));
    return status;
  }

  Future<String> offlineHome() async {
    final paths = await _call<Map>('sharedPaths');
    final home = paths['offlineCoreHome'];
    if (home is! String || !p.isAbsolute(home)) {
      throw const IOSCoreException('离线目录无效');
    }
    return home;
  }

  int beginPendingStart() => ++_startGeneration;

  void cancelPendingStart() => _startGeneration++;

  void checkPendingStart(int generation) {
    if (generation != _startGeneration) throw const IOSCoreException('启动已取消');
  }

  Future<T> startStage<T>(int generation, Future<T> Function() stage) async {
    checkPendingStart(generation);
    final result = await stage();
    checkPendingStart(generation);
    return result;
  }

  Future<void> startSnapshot(
    IOSSnapshotInputs inputs,
    CoreState state,
    Map<String, Object?> network, {
    required int generation,
  }) async {
    void checkCancelled() {
      checkPendingStart(generation);
    }

    checkCancelled();
    await refreshStatus();
    checkCancelled();
    if (!status.vpnSupported) throw const IOSCoreException('模拟器不支持系统 VPN');
    if (status.connected) return;
    if (status.transitioning) throw const IOSCoreException('系统正在切换隧道');
    final snapshot = await _call<Map>('publishSnapshot', {
      'setup': jsonEncode(inputs.setup),
      'state': jsonEncode(state),
      'network': network,
      'resources': inputs.resources,
    }, checkCancelled);
    checkCancelled();
    final revision = snapshot['revision'];
    final hash = snapshot['manifestHash'];
    if (snapshot['schemaVersion'] != 1 ||
        revision is! String ||
        revision.isEmpty ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
      throw const IOSCoreException('快照绑定无效');
    }
    _acceptStatus(
      await _call<Map>('startVpn', {
        'revision': revision,
        'manifestHash': hash,
      }, checkCancelled),
    );
    await _waitStable(true, checkCancelled);
  }

  Future<void> stopVpn({bool cancelPending = true}) async {
    if (cancelPending) cancelPendingStart();
    _acceptStatus(await _call<Map>('stopVpn'));
    await _waitStable(false, () {});
  }

  Future<void> _waitStable(
    bool connected,
    void Function() checkCancelled,
  ) async {
    final deadline = DateTime.now().add(transitionTimeout);
    var sawTransition = status.transitioning;
    while (true) {
      checkCancelled();
      if (connected && status.connected) return;
      if (!connected && !status.connected && !status.transitioning) return;
      sawTransition = sawTransition || status.transitioning;
      if (connected &&
          sawTransition &&
          !status.connected &&
          !status.transitioning) {
        throw const IOSCoreException('系统隧道启动失败');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const IOSCoreException('系统隧道等待超时');
      }
      await Future<void>.delayed(pollInterval);
      await refreshStatus();
    }
  }

  @override
  Future<T> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
    FutureOr<T> Function()? onTimeout,
    T? defaultValue,
  }) async {
    if ({
      ActionMethod.startListener,
      ActionMethod.stopListener,
      ActionMethod.crash,
    }.contains(method)) {
      throw const IOSCoreException('iOS 禁止桌面生命周期操作');
    }
    try {
      final actionID = 'ios#${++_id}';
      final result = ActionResult.fromJson(
        jsonDecode(
          await _call<String>('coreAction', {
            'action': jsonEncode(
              Action(id: actionID, method: method, data: data),
            ),
            'transport': 'auto',
            'timeoutMs': (timeout?.inMilliseconds ?? 10000).clamp(1, 30000),
          }),
        ),
      );
      if (result.id != actionID) throw const IOSCoreException('核心响应绑定无效');
      if (result.method != method) throw const IOSCoreException('核心响应类型无效');
      if (result.code != ResultType.success) {
        throw const IOSCoreException('核心操作拒绝');
      }
      if (method == ActionMethod.validateConfig) {
        final diagnostic = result.data;
        if (diagnostic is! String) throw const IOSCoreException('配置诊断类型无效');
        // code=0 只表示请求完成；校验诊断不能携带对象名、URL 或原始配置。
        final category = diagnostic.isEmpty
            ? ''
            : diagnostic.toLowerCase().contains('duplicate name')
            ? 'duplicate name'
            : '配置校验失败';
        return category as T;
      }
      if (method == ActionMethod.getConfig) return result.toResult as T;
      if (method == ActionMethod.convertAgeSecretKeyToPublicKey) {
        return Result<String>.success(result.data as String) as T;
      }
      if (method == ActionMethod.generateAgeKeyPair) {
        return Map<String, String>.from(result.data as Map) as T;
      }
      return result.data as T;
    } on IOSCoreException {
      rethrow;
    } catch (_) {
      throw const IOSCoreException('核心响应无效');
    }
  }

  // iOS 不订阅原始核心日志，避免配置、订阅地址或凭据进入日志。
  @override
  Future<void> startLog() async {}
  @override
  Future<void> stopLog() async {}

  @override
  void sendMessage(String message) => throw const IOSCoreException('不支持未受控消息');
  @override
  Future<void> reStart() async => stopVpn();
  @override
  Future<bool> destroy() async {
    cancelPendingStart();
    await _events?.cancel();
    _events = null;
    return true;
  }
}

final iosClash = IOSClash();
