/// API 入口域名池管理（F-DOMAIN-1/2/4 内核）。
///
/// M1：单一内置域名 + 失败计数/轮换结构；M3（域名切换加固）扩展为
/// 可变域名池（引导源下发/手动输入合并）、救援态判定与持久化钩子。
/// 纯 Dart，可单测。
library;

class XboardDomainManager {
  XboardDomainManager({List<String>? domains})
    : _domains = List<String>.unmodifiable(
        domains == null || domains.isEmpty ? defaultDomains : domains,
      ),
      assert(domains == null || domains.every(_isHttpUrl), '域名须为 http(s) URL');

  /// M0 测试面板；正式域名池由引导源下发后替换。
  static const List<String> defaultDomains = [
    'https://cloud.microsoftnexushub.top:8443',
  ];

  static bool _isHttpUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

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
    final activeNow = _domains[_activeIndex];
    final merged = <String>[];
    for (final domain in newDomains) {
      if (!merged.contains(domain)) merged.add(domain);
    }
    for (final domain in _domains) {
      if (!merged.contains(domain)) merged.add(domain);
    }
    _domains = List.unmodifiable(merged);
    if (!newDomains.contains(activeNow)) {
      _activeIndex = 0;
      _failureCounts[activeNow] = failureThreshold;
    }
    onPoolChanged?.call(_domains);
  }

  /// 救援模式手动输入的域名：校验通过后并入池并立即切换（失败计数清零）。
  /// 返回是否采纳；未通过校验返回 false。
  bool addDomain(String url) {
    if (!_isHttpUrl(url)) return false;
    final index = _domains.indexOf(url);
    if (index >= 0) {
      _activeIndex = index;
      return true;
    }
    _domains = List.unmodifiable([..._domains, url]);
    _activeIndex = _domains.length - 1;
    _failureCounts[url] = 0;
    onPoolChanged?.call(_domains);
    return true;
  }

  /// 清空失败计数（救援"一键重试"）。
  void resetFailures() {
    _failureCounts.clear();
  }

  static const int failureThreshold = 2;
}
