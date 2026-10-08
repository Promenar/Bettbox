import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/helper/helper.dart';
import 'package:bett_box/models/core.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/utils/frame_codec.dart';
import 'package:bett_box/utils/platform_check.dart';
import 'package:path/path.dart' as p;
import 'message.dart';
import 'supervisor/supervisor_codec.dart';
import 'supervisor/supervisor_method_channel.dart';
import 'supervisor/supervisor_application.dart';
import 'supervisor/supervisor_session.dart';
import 'supervisor/supervisor_transport.dart';

class ClashService extends ClashHandlerInterface {
  static ClashService? _instance;

  Completer<ServerSocket> serverCompleter = Completer();

  Completer<Socket> socketCompleter = Completer();

  bool isStarting = false;
  bool _isDestroying = false;

  Process? process;

  Completer<void>? _restartCompleter;

  TransportType _transportType = TransportType.unixSocket;
  String? _socketPath;
  int? _tcpPort;
  SupervisorApplication? _macApplication;

  factory ClashService() {
    _instance ??= ClashService._internal();
    return _instance!;
  }

  ClashService._internal() {
    if (Platform.isMacOS) {
      _macApplication = SupervisorApplication(
        buildSession: (result, revoked) => SupervisorSession(
          native: const MethodChannelSupervisorNative(),
          factory: ProcessSupervisorTransportFactory(),
          onResult: result,
          onRevoked: revoked,
        ),
        onEvent: clashMessage.dispatch,
        onRuntimeChanged: (startedAt) => globalState.startTime = startedAt,
      );
      unawaited(
        _macApplication!.initialize().then<void>(
          (_) {},
          onError: (Object _) {},
        ),
      );
    } else {
      _initTransport();
    }
  }

  DateTime? get macStartedAt => _macApplication?.startedAt;

  Future<bool> setMacSystemProxyPreference({
    required bool enabled,
    required List<String> bypass,
  }) async {
    if (!Platform.isMacOS) return false;
    return _macApplication!.setSystemProxyPreference(
      enabled: enabled,
      bypass: bypass,
    );
  }

  @override
  Future<bool> startListener() async {
    if (!Platform.isMacOS) return super.startListener();
    final settings = globalState.config.networkProps;
    if (!await setMacSystemProxyPreference(
      enabled: settings.systemProxy,
      bypass: settings.bypassDomain,
    )) {
      return false;
    }
    return _macApplication!.startRuntime();
  }

  @override
  Future<bool> stopListener() async {
    if (!Platform.isMacOS) return super.stopListener();
    return _macApplication!.stopRuntime();
  }

  Future<void> _initTransport() async {
    _transportType = await PlatformChecker.getRecommendedTransport();

    if (_transportType == TransportType.unixSocket) {
      final random = Random().nextInt(10000);
      final tempDir = Directory.systemTemp.path;
      _socketPath = p.join(tempDir, 'Bettbox_$random.sock');
      commonPrint.log('Using Unix Domain Socket: $_socketPath');
    } else {
      _tcpPort = PlatformChecker.getRandomPort();
      commonPrint.log('Using TCP Socket on port: $_tcpPort');
    }

    _initServer();
    reStart();
  }

  Future<void> _initServer() async {
    runZonedGuarded(
      () async {
        late final ServerSocket server;

        if (_transportType == TransportType.unixSocket) {
          final address = InternetAddress(
            _socketPath!,
            type: InternetAddressType.unix,
          );
          await _deleteSocketFile();
          server = await ServerSocket.bind(address, 0, shared: true);
        } else {
          server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          _tcpPort = server.port;
          commonPrint.log('TCP Server bound to port: $_tcpPort');
        }

        serverCompleter.complete(server);
        await for (final socket in server) {
          await _destroySocket();
          socketCompleter.complete(socket);

          socket
              .transform(FrameDecoderTransformer())
              .listen(
                (data) {
                  handleResult(ActionResult.fromJson(json.decode(data)));
                },
                onError: (error) {
                  if (_isDestroying || globalState.isExiting) return;
                  commonPrint.log('Frame decode error: $error');
                },
                onDone: () {
                  commonPrint.log('Socket connection closed');
                },
              );
        }
      },
      (error, stack) {
        if (_isDestroying || globalState.isExiting) return;
        commonPrint.log(error.toString());
        if (error is SocketException &&
            !_isDestroying &&
            !globalState.isExiting) {
          globalState.showNotifier(error.toString());
        }
      },
    );
  }

  @override
  Future<void> reStart() async {
    if (Platform.isMacOS) {
      isStarting = true;
      _isDestroying = false;
      try {
        await _macApplication!.restart();
      } finally {
        isStarting = false;
      }
      return;
    }
    final completer = Completer<void>();
    final previous = _restartCompleter;
    _restartCompleter = completer;

    if (previous != null) {
      await previous.future;
    }

    try {
      // Perform a real restart so every caller is guaranteed to see a fresh
      // core after this call returns. Queued calls will run sequentially.
      await _doRestart();
    } finally {
      if (_restartCompleter == completer) {
        _restartCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _doRestart() async {
    isStarting = true;
    _isDestroying = false;

    await _destroySocket();

    process?.kill();
    if (process != null) {
      await process!.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    process = null;

    socketCompleter = Completer();

    final serverSocket = await serverCompleter.future;

    final String arg;
    if (_transportType == TransportType.unixSocket) {
      arg = _socketPath!;
    } else {
      arg = '${serverSocket.port}';
    }

    final homeDirPath = await appPath.homeDirPath;
    final environment = Map<String, String>.from(Platform.environment);
    environment['SAFE_PATHS'] = homeDirPath;

    if (system.isWindows) {
      final serviceOk = await windows?.registerService() ?? false;
      if (serviceOk) {
        final started = await helperClient.startCore(
          corePath: appPath.corePath,
          arg: arg,
          homeDir: homeDirPath,
        );
        if (started) {
          await _waitForCoreReady();
          isStarting = false;
          if (system.isWindows &&
              globalState.config.appSetting.enableHighPriority) {
            unawaited(
              helperClient
                  .setProcessPriority(
                    '${AppIdentity.coreExecutableName}.exe',
                    true,
                  )
                  .catchError((e) {
                    commonPrint.log('Failed to set core process priority: $e');
                    return false;
                  }),
            );
          }
          return;
        }
        commonPrint.log(
          'Helper start core failed, falling back to normal mode',
        );
      }
    }

    process = await Process.start(appPath.corePath, [
      arg,
    ], environment: environment);
    process?.stdout.listen((_) {});
    process?.stderr.listen((e) {
      final error = utf8.decode(e);
      if (error.isNotEmpty) commonPrint.log(error);
    });
    await _waitForCoreReady();
    isStarting = false;
    if (system.isWindows && globalState.config.appSetting.enableHighPriority) {
      unawaited(
        helperClient
            .setProcessPriority('${AppIdentity.coreExecutableName}.exe', true)
            .catchError((e) {
              commonPrint.log('Failed to set core process priority: $e');
              return false;
            }),
      );
    }
  }

  Future<void> _waitForCoreReady() async {
    try {
      await socketCompleter.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      commonPrint.log('Core ready timeout after 5s');
    }
  }

  @override
  destroy() async {
    _isDestroying = true;
    if (Platform.isMacOS) {
      final stopped = await _macApplication!.shutdown();
      if (!stopped) _isDestroying = false;
      return stopped;
    }
    final server = await serverCompleter.future;
    await server.close();
    await _deleteSocketFile();
    return true;
  }

  @override
  sendMessage(String message) async {
    if (Platform.isMacOS) {
      throw const SupervisorFailure('macOS要求受控请求通道');
    }
    if (_isDestroying || globalState.isExiting) {
      return;
    }
    final socket = await socketCompleter.future;
    try {
      final frame = FrameCodec.encode(message);
      socket.add(frame);
    } on SocketException catch (e) {
      if (_isDestroying || globalState.isExiting || isStarting) {
        commonPrint.log(
          'Ignored message send on closed socket during transition: $e',
        );
        return;
      }
      rethrow;
    } on StateError catch (e) {
      if (_isDestroying || globalState.isExiting || isStarting) {
        commonPrint.log(
          'Ignored message send on closed socket during transition: $e',
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _deleteSocketFile() async {
    if (_transportType == TransportType.unixSocket && _socketPath != null) {
      final file = File(_socketPath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _destroySocket() async {
    if (socketCompleter.isCompleted) {
      final lastSocket = await socketCompleter.future;
      await lastSocket.close();
      socketCompleter = Completer();
    }
  }

  @override
  shutdown() async {
    _isDestroying = true;
    if (Platform.isMacOS) {
      final stopped = await _macApplication!.shutdown();
      if (!stopped) _isDestroying = false;
      return stopped;
    }
    if (system.isWindows) {
      await helperClient.stopCore();
    }
    await _destroySocket();
    process?.kill();
    process = null;
    return true;
  }

  Future<bool> checkCoreHealth({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_isDestroying || globalState.isExiting || isStarting) return false;
    if (Platform.isMacOS) {
      if (_macApplication?.isReady != true) return false;
    } else if (!socketCompleter.isCompleted) {
      return false;
    }
    try {
      final result = await invoke<bool>(
        method: ActionMethod.getIsInit,
        timeout: timeout,
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> preload() async {
    if (Platform.isMacOS) {
      return _macApplication!.preload();
    }
    await serverCompleter.future;
    return true;
  }

  @override
  Future<T> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
    FutureOr<T> Function()? onTimeout,
    T? defaultValue,
  }) async {
    if (!Platform.isMacOS) {
      return super.invoke<T>(
        method: method,
        data: data,
        timeout: timeout,
        onTimeout: onTimeout,
        defaultValue: defaultValue,
      );
    }
    try {
      final raw = await _macApplication!.request(
        method: method.name,
        data: data,
        timeout: timeout ?? const Duration(seconds: 30),
      );
      final result = ActionResult.fromJson(raw);
      final Object? value =
          method == ActionMethod.getConfig ||
              method == ActionMethod.convertAgeSecretKeyToPublicKey
          ? result.toResult
          : result.data;
      if (value is! T) throw const SupervisorFailure('内核结果类型拒绝');
      return value;
    } on TimeoutException {
      if (onTimeout != null) return onTimeout();
      final Object? value =
          defaultValue ??
          (T == String
              ? ''
              : T == bool
              ? false
              : T == Map
              ? <dynamic, dynamic>{}
              : null);
      if (value is T) return value;
      rethrow;
    }
  }
}

final clashService = system.isDesktop ? ClashService() : null;
