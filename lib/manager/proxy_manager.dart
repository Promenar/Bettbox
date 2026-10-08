import 'package:bett_box/common/common.dart';
import 'package:bett_box/clash/service.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _updateProxy(ProxyState proxyState) async {
    if (system.isMacOS) {
      try {
        final accepted = await clashService!.setMacSystemProxyPreference(
          enabled: proxyState.systemProxy,
          bypass: proxyState.bypassDomain,
        );
        if (!accepted) {
          globalState.showNotifier(appLocalizations.connectionStateUnconfirmed);
        }
      } catch (_) {
        globalState.showNotifier(appLocalizations.connectionStateUnconfirmed);
      }
      return;
    }
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart && systemProxy) {
      proxy?.startProxy(port, proxyState.bypassDomain);
    } else {
      proxy?.stopProxy();
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (system.isMacOS &&
          prev != null &&
          prev.systemProxy == next.systemProxy &&
          listEquals(prev.bypassDomain, next.bypassDomain)) {
        return;
      }
      if (prev != next) {
        _updateProxy(next);
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
