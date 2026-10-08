import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/manager/smart_auto_stop_policy.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/plugins/smart_stop_completion.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

/// Smart Auto Stop Manager
class SmartAutoStopManager extends ConsumerStatefulWidget {
  final Widget child;

  const SmartAutoStopManager({super.key, required this.child});

  @override
  ConsumerState<SmartAutoStopManager> createState() =>
      _SmartAutoStopManagerState();
}

class _SmartAutoStopManagerState extends ConsumerState<SmartAutoStopManager> {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  final _checkLock = Lock();

  int _checkSequence = 0;
  int _settingsRevision = 0;

  late final NativeEventCallback _nativeEventCallback;

  @override
  void initState() {
    super.initState();
    _initConnectivityListener();
    _initNativeNetworkListener();
  }

  void _initNativeNetworkListener() {
    _nativeEventCallback = (String method, dynamic arguments) async {
      if (method == 'networkChanged') {
        _onNativeNetworkChanged();
      } else if (method == 'quickResponse') {
        final vpnProps = ref.read(vpnSettingProvider);
        if (vpnProps.quickResponse) {
          final startTime = globalState.startTime;
          if (startTime != null &&
              DateTime.now().difference(startTime) <
                  const Duration(seconds: 3)) {
            return;
          }
          clashCore.closeConnections();
        }
      }
    };
    service?.addNativeEventCallback(_nativeEventCallback);
  }

  void _onNativeNetworkChanged() {
    final vpnProps = ref.read(vpnSettingProvider);
    if (!vpnProps.smartAutoStop) return;
    _debouncedCheckCurrentNetwork();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ref.listenManual(vpnSettingProvider, (prev, next) {
      if (prev?.smartAutoStop != next.smartAutoStop ||
          prev?.smartAutoStopNetworks != next.smartAutoStopNetworks) {
        _onSettingsChanged();
      }
    });
  }

  void _initConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      _onConnectivityChanged(results);
    });
  }

  void _onSettingsChanged() {
    _settingsRevision++;
    // 设置变化与网络变化共用串行入口，关闭或清空规则也能恢复。
    _checkCurrentNetwork();
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final vpnProps = ref.read(vpnSettingProvider);
    if (!vpnProps.smartAutoStop) return;

    _debouncedCheckCurrentNetwork();
  }

  void _debouncedCheckCurrentNetwork() {
    final currentSequence = ++_checkSequence;

    Future.delayed(const Duration(milliseconds: 1000), () async {
      if (currentSequence != _checkSequence) {
        commonPrint.log('Smart Auto Stop: Skipping outdated network check');
        return;
      }
      await _checkCurrentNetwork();
    });
  }

  Future<void> _checkCurrentNetwork() async {
    await _checkLock.synchronized(() async {
      if (!mounted) return;
      final revision = _settingsRevision;
      final vpnProps = ref.read(vpnSettingProvider);
      final networks = vpnProps.smartAutoStopNetworks;
      List<String> candidateIps = [];
      // 关闭或空规则已确定不匹配，无需等待地址查询。
      if (vpnProps.smartAutoStop && networks.trim().isNotEmpty) {
        if (system.isAndroid) {
          candidateIps = await _getNativeLocalIpAddresses();
        } else {
          final ip = await _getLocalIpAddress();
          candidateIps = ip != null ? [ip] : [];
        }
      }
      // 地址查询期间设置变化时，由排队的新检查处理，拒绝旧决策。
      if (!mounted || revision != _settingsRevision) return;
      final isSmartStopped = ref.read(isSmartStoppedProvider);
      final decision = decideSmartAutoStop(
        enabled: vpnProps.smartAutoStop,
        networks: networks,
        addresses: candidateIps,
        suspended: isSmartStopped,
        running: ref.read(runTimeProvider) != null || globalState.isStart,
      );
      switch (decision) {
        case SmartAutoStopDecision.stop:
          await _stopVpn();
        case SmartAutoStopDecision.resume:
          ref.read(isSmartStoppedProvider.notifier).set(false);
          await _restartVpn();
        case SmartAutoStopDecision.none:
          break;
      }
    });
  }

  Future<List<String>> _getNativeLocalIpAddresses() async {
    try {
      final serviceInstance = service;
      if (serviceInstance != null) {
        final ips = await serviceInstance.getLocalIpAddresses();
        if (ips.isNotEmpty) return ips;
      }
    } catch (e) {
      commonPrint.log('Smart Auto Stop: Native IP error: $e');
    }
    // Fallback to Flutter layer
    final ip = await _getLocalIpAddress();
    return ip != null ? [ip] : [];
  }

  Future<String?> _getLocalIpAddress() async {
    return await utils.getLocalIpAddress();
  }

  Future<void> _stopVpn() async {
    if (system.isAndroid) {
      // Android 保留服务；只有原生停止确认后才清理运行显示。
      await completeSmartStop(
        stop: () async => service?.smartStop(),
        isSuspended: () async => await service?.isSmartStopped() ?? false,
        currentSession: () => globalState.startTime,
        commit: () {
          ref.read(isSmartStoppedProvider.notifier).set(true);
          globalState.startTime = null;
          clashCore.resetTraffic();
          ref.read(trafficsProvider.notifier).clear();
          ref.read(totalTrafficProvider.notifier).value = Traffic();
          ref.read(runTimeProvider.notifier).value = null;
        },
      );
    } else {
      // Desktop: Full stop
      await globalState.appController.updateStatus(false);
      ref.read(isSmartStoppedProvider.notifier).set(true);
    }
  }

  Future<void> _restartVpn() async {
    if (system.isAndroid) {
      // Android: Resume from smart-stop mode
      await service?.setSmartStopped(false);
      await service?.smartResume();

      globalState.startTime = DateTime.now();
      ref.read(runTimeProvider.notifier).value = 0;
      globalState.appController.addCheckIpNumDebounce();
    } else {
      // Desktop: Full start
      await globalState.appController.updateStatus(true);
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    service?.removeNativeEventCallback(_nativeEventCallback);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
