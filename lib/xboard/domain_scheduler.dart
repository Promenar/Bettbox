/// 域名自愈调度器（F-DOMAIN-2/3/5）。
///
/// 职责：
/// - 启动：加载持久化域名池（含引导源）→ 接线持久化钩子 → 异步引导源刷新
///   + 健康探测（`guest/comm/config`）；
/// - 刷新（启动/定时/救援重试）：引导源 + 探测，结束时若活跃域名发生
///   变化（连接层失败自动轮换或引导源主动改派）→ 订阅 URL host 热替换
///   与订阅刷新（F-DOMAIN-5，回调 [XboardDomainCallbacks.onActiveChanged]）；
/// - 救援模式：全池失败后提供一键重试 / 手动输入域名（F-DOMAIN-4）；
/// - 定时（默认 6h）引导源拉取（F-DOMAIN-2 触发时机③）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'bootstrap.dart';
import 'domain_manager.dart';
import 'models.dart';
import 'secure_store.dart';

/// 域名池快照（供 UI 订阅：救援横幅/手动输入入口的展示依据）。
class XboardDomainState {
  const XboardDomainState({
    required this.domains,
    required this.active,
    required this.rescue,
  });

  final List<String> domains;
  final String active;
  final bool rescue;

  factory XboardDomainState.of(XboardDomainManager manager) => XboardDomainState(
    domains: manager.domains,
    active: manager.active,
    rescue: manager.allDomainsFailing,
  );
}

final xboardDomainStateProvider = StateProvider<XboardDomainState?>((ref) => null);

/// 调度器回调集合（由 session provider 用 Riverpod ref 闭包构造）。
class XboardDomainCallbacks {
  const XboardDomainCallbacks({
    required this.onPoolChanged,
    required this.onActiveChanged,
  });

  /// 域名池变化（冷启动加载/引导源合并/手动添加）→ 推送 UI 快照。
  final void Function(List<String> domains) onPoolChanged;

  /// 活跃域名实际切换 → 订阅 URL host 热替换 + 刷新（F-DOMAIN-5）。
  final Future<void> Function(String baseUrl) onActiveChanged;
}

class XboardDomainScheduler {
  XboardDomainScheduler({
    required XboardDomainManager domainManager,
    required XboardSecureStore secureStore,
    required XboardBootstrapClient bootstrapClient,
    required XboardApiClient apiClient,
    required XboardDomainCallbacks callbacks,
    this.probeInterval = const Duration(hours: 6),
  }) : _manager = domainManager,
       _store = secureStore,
       _bootstrap = bootstrapClient,
       _api = apiClient,
       _callbacks = callbacks;

  final XboardDomainManager _manager;
  final XboardSecureStore _store;
  final XboardBootstrapClient _bootstrap;
  final XboardApiClient _api;
  final XboardDomainCallbacks _callbacks;
  final Duration probeInterval;

  bool _started = false;
  List<String> _sources = [];

  /// 启动：加载持久化池 → 接线 → 立即异步刷新。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final saved = await _store.readDomainPool();
    if (saved != null) {
      _manager.updatePool(saved.domains);
      _sources = saved.sources;
    }
    _manager.onPoolChanged = (domains) async {
      await _store.saveDomainPool(domains: domains, sources: _sources);
      _callbacks.onPoolChanged(domains);
    };
    _callbacks.onPoolChanged(_manager.domains);
    // 应用生命周期级定时探测（F-DOMAIN-2 触发时机③）
    Timer.periodic(probeInterval, (_) => refresh());
    await refresh();
  }

  /// 引导源刷新 + 健康探测；结束时活跃域名变化 → 订阅同步。
  Future<void> refresh() async {
    final before = _manager.active;
    final doc = await _pullBootstrap();
    if (doc != null && doc.bootstrapSources.isNotEmpty) {
      _sources = doc.bootstrapSources;
      _manager.onPoolChanged?.call(_manager.domains);
    }
    await _probe();
    if (_manager.active != before) {
      _callbacks.onPoolChanged(_manager.domains);
      await _callbacks.onActiveChanged(_manager.active);
    }
  }

  /// 救援"一键重试"：清空失败计数 → 拉引导源 → 探测。
  Future<void> retry() async {
    _manager.resetFailures();
    await refresh();
  }

  /// 救援"手动输入新域名"：采纳并切到该域名后探测，成功返回 true。
  Future<bool> useManualDomain(String url) async {
    if (!_manager.addDomain(url)) return false;
    final ok = await _probe();
    if (ok) {
      await _callbacks.onActiveChanged(_manager.active);
    }
    return ok;
  }

  Future<XboardBootstrapDoc?> _pullBootstrap() async {
    final sources = [
      ..._sources,
      ...builtinBootstrapSources(_manager.domains),
    ];
    final doc = await _bootstrap.fetch(
      sources,
      onError: (source, error) {
        debugPrint('[XBOARD_DOMAIN] bootstrap $source failed: $error');
      },
    );
    if (doc == null) return null;
    _manager.updatePool(doc.apiDomains);
    debugPrint('[XBOARD_DOMAIN] bootstrap ok: ${doc.apiDomains}');
    return doc;
  }

  Future<bool> _probe() async {
    try {
      await _api.get('/guest/comm/config');
      _manager.reportSuccess();
      return true;
    } on XboardException catch (error) {
      debugPrint('[XBOARD_DOMAIN] probe fail: ${error.message}');
      // 连接层失败已在 apiClient 内触发轮换；业务错误视为可达，不轮换。
      return !error.isConnection;
    }
  }
}
