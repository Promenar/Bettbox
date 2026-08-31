/// API 入口域名池管理（F-DOMAIN-1/2 的 M1 骨架）。
///
/// M1：单一内置域名 + 失败计数/轮换结构就位；M3 接入引导源（bootstrap sources）
/// 与订阅 URL host 热替换。纯 Dart，可单测。
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

  static bool _isHttpUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  final List<String> _domains;
  int _activeIndex = 0;
  final Map<String, int> _failureCounts = {};

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

  static const int failureThreshold = 2;
}
