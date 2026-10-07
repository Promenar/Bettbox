/// API 入口域名池管理（F-DOMAIN-1/2/4 内核）。
///
/// M1：单一内置域名 + 失败计数/轮换结构；M3（域名切换加固）扩展为
/// 可变域名池（引导源下发/手动输入合并）、救援态判定与持久化钩子。
/// 纯 Dart，可单测。
library;

import 'url_policy.dart';

class XboardDomainManager {
  XboardDomainManager({List<String>? domains})
    : _domains = _validatedDomains(domains);

  /// 当前服务入口；引导源可更新顺序与追加兼容入口。
  static const List<String> defaultDomains = [
    'https://api.bingcn.site',
    'https://cloud.microsoftnexushub.top:8443',
  ];

  static List<String> _validatedDomains(List<String>? values) {
    if (values == null || values.isEmpty) return defaultDomains;
    final result = <String>[];
    for (final value in values) {
      final origin = normalizePanelOrigin(value);
      if (origin == null) throw ArgumentError('API 入口须为无认证的 HTTPS 根地址');
      if (!result.contains(origin)) result.add(origin);
    }
    return List.unmodifiable(result);
  }

  List<String> _domains;
  int _activeIndex = 0;
  final Map<String, int> _failureCounts = {};

  /// 池变化（引导源合并/手动添加/轮换触发持久化）时上报。
  Future<void> Function(List<String> domains)? onPoolChanged;

  List<String> get domains => List.unmodifiable(_domains);
  String get active => _domains[_activeIndex];
  int get activeFailureCount => _failureCounts[active] ?? 0;

  /// 连接层失败上报：同一域名连续失败 [XboardFailureThreshold] 次后自动轮换。
  void reportConnectionFailure() {
    final host = active;
    _failureCounts[host] = (_failureCounts[host] ?? 0) + 1;
    if ((_failureCounts[host] ?? 0) >= failureThreshold) {
      rotateNext();
    }
  }

  /// 请求成功即清零当前域名失败计数。
  void reportSuccess() {
    _failureCounts[active] = 0;
  }

  /// 轮换到下一个候选域名，返回是否发生了切换。
  bool rotateNext() {
    if (_domains.length <= 1) return false;
    _activeIndex = (_activeIndex + 1) % _domains.length;
    return true;
  }

  /// 全池连续失败（进入救援模式的判定条件）。
  bool get allDomainsFailing =>
      _failureCounts.length >= _domains.length &&
      _domains.every((d) => (_failureCounts[d] ?? 0) >= failureThreshold);

  /// 引导源/手动域名并入域名池（F-DOMAIN-1/3）。
  ///
  /// 语义：引导源列表为权威——按其顺序排前，旧池中未在新列表出现的域名
  /// 追加在后（保序）作为轮换备选；当前活跃域名若不在新列表（被引导源
  /// 退役），立即切到新列表首个域名，并将其标记为已失效。
  void updatePool(List<String> newDomains) {
    final accepted = newDomains
        .map(normalizePanelOrigin)
        .whereType<String>()
        .toSet()
        .toList();
    if (accepted.isEmpty) return;
    final activeNow = _domains[_activeIndex];
    final merged = <String>[];
    for (final domain in accepted) {
      if (!merged.contains(domain)) merged.add(domain);
    }
    for (final domain in _domains) {
      if (!merged.contains(domain)) merged.add(domain);
    }
    _domains = List.unmodifiable(merged);
    if (!accepted.contains(activeNow)) {
      _activeIndex = 0;
      _failureCounts[activeNow] = failureThreshold;
    } else {
      _activeIndex = _domains.indexOf(activeNow);
    }
    onPoolChanged?.call(_domains);
  }

  /// 救援模式手动输入的域名：校验通过后并入池并立即切换（失败计数清零）。
  /// 返回是否采纳；未通过校验返回 false。
  bool addDomain(String url) {
    final origin = normalizePanelOrigin(url);
    if (origin == null) return false;
    final index = _domains.indexOf(origin);
    if (index >= 0) {
      _activeIndex = index;
      _failureCounts[origin] = 0;
      return true;
    }
    _domains = List.unmodifiable([..._domains, origin]);
    _activeIndex = _domains.length - 1;
    _failureCounts[origin] = 0;
    onPoolChanged?.call(_domains);
    return true;
  }

  /// 清空失败计数（救援"一键重试"）。
  void resetFailures() {
    _failureCounts.clear();
  }

  static const int failureThreshold = 2;
}
