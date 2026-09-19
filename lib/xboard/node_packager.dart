/// 节点地域解析与商业包装（F-NODE-1/2/3/5）。
///
/// 从订阅节点名称解析地域 → 聚合为地域组 → 节点名脱敏为"地域代号-序号"。
/// 纯 Dart 可单测；生成结果直接注入 mihomo 配置。
library;

class XboardRegionRule {
  const XboardRegionRule(this.code, this.name, this.flag, this.pattern);

  final String code;
  final String name;

  /// 国旗 emoji，用于地域组名展示（F-NODE-3 首页地区列表）。
  final String flag;
  final RegExp pattern;
}

/// 全局负载均衡开关（F-NODE-4）：由 UI 层通过 [setXboardLoadBalanceEnabled] 切换，
/// 持久化由 `XboardSecureStore` 承担，启动时从存储恢复后注入。默认开启。
bool _xboardLoadBalanceEnabled = true;
void setXboardLoadBalanceEnabled(bool v) => _xboardLoadBalanceEnabled = v;
bool get isXboardLoadBalanceEnabled => _xboardLoadBalanceEnabled;

/// 地域识别规则表（顺序即优先级）。
///
/// 覆盖 emoji 旗帜 / 中文 / 英文全称与常见缩写；支持随版本与远端配置扩展。
final List<XboardRegionRule> kRegionRules = [
  XboardRegionRule('HK', '香港', '🇭🇰', RegExp(r'🇭🇰|香港|港|(?<![A-Za-z])HK(?![A-Za-z])|HKG|Hong ?Kong', caseSensitive: false)),
  XboardRegionRule('TW', '台湾', '🇹🇼', RegExp(r'🇹🇼|台湾|臺灣|台|(?<![A-Za-z])TW(?![A-Za-z])|TPE|Taiwan', caseSensitive: false)),
  XboardRegionRule('SG', '新加坡', '🇸🇬', RegExp(r'🇸🇬|新加坡|獅城|狮城|(?<![A-Za-z])SG(?![A-Za-z])|SIN|Singapore', caseSensitive: false)),
  XboardRegionRule('JP', '日本', '🇯🇵', RegExp(r'🇯🇵|日本|(?<!尼)日(?!利亚|内瓦)|(?<![A-Za-z])JP(?![A-Za-z])|JPN|Japan', caseSensitive: false)),
  XboardRegionRule('KR', '韩国', '🇰🇷', RegExp(r'🇰🇷|韩国|韓國|韩|(?<![A-Za-z])KR(?![A-Za-z])|KOR|Korea', caseSensitive: false)),
  XboardRegionRule('US', '美国', '🇺🇸', RegExp(r'🇺🇸|美国|美國|美|(?<![A-Za-z])US(?![A-Za-z])|USA|America|Los ?Angeles|San ?Jose|Seattle|Silicon', caseSensitive: false)),
  XboardRegionRule('MY', '马来西亚', '🇲🇾', RegExp(r'🇲🇾|马来西亚|馬來西亞|(?<![A-Za-z])MY(?![A-Za-z])|Malaysia', caseSensitive: false)),
  XboardRegionRule('TH', '泰国', '🇹🇭', RegExp(r'🇹🇭|泰国|泰國|(?<![A-Za-z])TH(?![A-Za-z])|Thailand', caseSensitive: false)),
  XboardRegionRule('VN', '越南', '🇻🇳', RegExp(r'🇻🇳|越南|(?<![A-Za-z])VN(?![A-Za-z])|Vietnam', caseSensitive: false)),
  XboardRegionRule('PH', '菲律宾', '🇵🇭', RegExp(r'🇵🇭|菲律宾|菲律賓|(?<![A-Za-z])PH(?![A-Za-z])|Philippines', caseSensitive: false)),
  XboardRegionRule('ID', '印尼', '🇮🇩', RegExp(r'🇮🇩|印尼|印度尼西亚|(?<![A-Za-z])ID(?![A-Za-z])|Jakarta|Indonesia', caseSensitive: false)),
  XboardRegionRule('UK', '英国', '🇬🇧', RegExp(r'🇬🇧|英国|英國|(?<![A-Za-z])UK(?![A-Za-z])|(?<![A-Za-z])GB(?![A-Za-z])|London|Britain', caseSensitive: false)),
  XboardRegionRule('DE', '德国', '🇩🇪', RegExp(r'🇩🇪|德国|德國|德|(?<![A-Za-z])DE(?![A-Za-z])|Germany|Frankfurt', caseSensitive: false)),
  XboardRegionRule('AU', '澳大利亚', '🇦🇺', RegExp(r'🇦🇺|澳大利亚|澳洲|(?<![A-Za-z])AU(?![A-Za-z])|Australia|Sydney', caseSensitive: false)),
  XboardRegionRule('TR', '土耳其', '🇹🇷', RegExp(r'🇹🇷|土耳其|(?<![A-Za-z])TR(?![A-Za-z])|Turkey|Istanbul', caseSensitive: false)),
  XboardRegionRule('BR', '巴西', '🇧🇷', RegExp(r'🇧🇷|巴西|(?<![A-Za-z])BR(?![A-Za-z])|Brazil', caseSensitive: false)),
  XboardRegionRule('AR', '阿根廷', '🇦🇷', RegExp(r'🇦🇷|阿根廷|(?<![A-Za-z])AR(?![A-Za-z])|Argentina', caseSensitive: false)),
  XboardRegionRule('IN', '印度', '🇮🇳', RegExp(r'🇮🇳|印度|(?<![A-Za-z])IN(?![A-Za-z])|India|Mumbai', caseSensitive: false)),
  XboardRegionRule('RU', '俄罗斯', '🇷🇺', RegExp(r'🇷🇺|俄罗斯|俄|(?<![A-Za-z])RU(?![A-Za-z])|Russia|Moscow', caseSensitive: false)),
  XboardRegionRule('UA', '乌克兰', '🇺🇦', RegExp(r'🇺🇦|乌克兰|(?<![A-Za-z])UA(?![A-Za-z])|Ukraine|Kyiv', caseSensitive: false)),
  XboardRegionRule('CH', '瑞士', '🇨🇭', RegExp(r'🇨🇭|瑞士|(?<![A-Za-z])CH(?![A-Za-z])|Switzerland|Zurich', caseSensitive: false)),
  XboardRegionRule('AE', '阿联酋', '🇦🇪', RegExp(r'🇦🇪|阿联酋|迪拜|(?<![A-Za-z])AE(?![A-Za-z])|Dubai|UAE', caseSensitive: false)),
  XboardRegionRule('NG', '尼日利亚', '🇳🇬', RegExp(r'🇳🇬|尼日利亚|(?<![A-Za-z])NG(?![A-Za-z])|Nigeria', caseSensitive: false)),
  XboardRegionRule('ZA', '南非', '🇿🇦', RegExp(r'🇿🇦|南非|(?<![A-Za-z])ZA(?![A-Za-z])|Africa', caseSensitive: false)),
  XboardRegionRule('CA', '加拿大', '🇨🇦', RegExp(r'🇨🇦|加拿大|(?<![A-Za-z])CA(?![A-Za-z])|Canada', caseSensitive: false)),
  XboardRegionRule('NL', '荷兰', '🇳🇱', RegExp(r'🇳🇱|荷兰|(?<![A-Za-z])NL(?![A-Za-z])|Netherlands|Amsterdam', caseSensitive: false)),
  XboardRegionRule('FR', '法国', '🇫🇷', RegExp(r'🇫🇷|法国|法國|(?<![A-Za-z])FR(?![A-Za-z])|France|Paris', caseSensitive: false)),
  XboardRegionRule('IQ', '伊拉克', '🇮🇶', RegExp(r'🇮🇶|伊拉克|(?<![A-Za-z])IQ(?![A-Za-z])|Iraq|Baghdad', caseSensitive: false)),
];

/// 地域解析结果。
class XboardRegionNode {
  const XboardRegionNode({
    required this.originalName,
    required this.sanitizedName,
    required this.regionCode,
    required this.regionName,
  });

  final String originalName;

  /// 脱敏名（如 HK-01），仅保留地域代号与序号。
  final String sanitizedName;
  final String regionCode;
  final String regionName;
}

/// 解析单个节点名 → 地域；未命中返回 null（归入"其他"）。
XboardRegionNode? resolveRegion(String nodeName) {
  for (final rule in kRegionRules) {
    if (rule.pattern.hasMatch(nodeName)) {
      return XboardRegionNode(
        originalName: nodeName,
        sanitizedName: nodeName,
        regionCode: rule.code,
        regionName: rule.name,
      );
    }
  }
  return null;
}

/// 地域包装结果：脱敏后的 proxies 与注入的自动组。
class XboardPackagedConfig {
  const XboardPackagedConfig({
    required this.proxies,
    required this.proxyGroups,
    required this.groupOf,
  });

  /// 规范化后的 proxies 列表（name 已脱敏）。
  final List<Map<String, dynamic>> proxies;

  /// 地域自动组 + 顶层选择器 + "自动（最优地域）"组。
  final List<Map<String, dynamic>> proxyGroups;

  /// 原始节点名 → 脱敏名（供连接页/日志映射）。
  final Map<String, String> groupOf;
}

/// 商业包装（F-NODE-3）：同地域节点包装为 url-test 自动组，
/// 顶层选择器提供"自动（最优地域）"与各地域。
///
/// [config] 为 mihomo 配置 Map；返回 null 表示无 proxies 可包装。
XboardPackagedConfig? packageNodes(
  Map<String, dynamic> config, {
  String defaultTestUrl = kDefaultTestUrl,
}) {
  final proxies = config['proxies'];
  if (proxies is! List || proxies.isEmpty) return null;

  final byRegion = <String, List<Map<String, dynamic>>>{};
  final nameMapping = <String, String>{};
  final counters = <String, int>{};
  final usedNames = <String>{};
  final allPatched = <Map<String, dynamic>>[];

  for (final entry in proxies) {
    if (entry is! Map<String, dynamic>) continue;
    final original = entry['name']?.toString() ?? '';
    final region = resolveRegion(original);
    final code = region?.regionCode ?? 'XX';
    final index = (counters[code] ?? 0) + 1;
    counters[code] = index;
    var sanitized = region == null ? 'XX-${_pad(index)}' : '$code-${_pad(index)}';
    var suffix = 0;
    var candidate = sanitized;
    while (usedNames.contains(candidate)) {
      suffix++;
      candidate = '${sanitized}_$suffix';
    }
    sanitized = candidate;
    usedNames.add(sanitized);
    final patched = Map<String, dynamic>.from(entry);
    patched['name'] = sanitized;
    byRegion.putIfAbsent(code, () => []).add(patched);
    allPatched.add(patched);
    // 保留首个映射（避免重复原名覆盖导致 flatProxies 重复）
    nameMapping.putIfAbsent(original, () => sanitized);
  }

  final groups = <Map<String, dynamic>>[];
  final regionGroupNames = <String>[];

  // 地域顺序按规则表优先级（kRegionRules 顺序），保证 HK 靠前。
  for (final rule in kRegionRules) {
    final nodes = byRegion.remove(rule.code);
    if (nodes == null || nodes.isEmpty) continue;
    final groupName = '${rule.flag} ${rule.name} ${rule.code}';
    regionGroupNames.add(groupName);
    if (_xboardLoadBalanceEnabled) {
      groups.add({
        'name': groupName,
        'type': 'load-balance',
        'strategy': 'sticky-sessions',
        'url': defaultTestUrl,
        'interval': 300,
        'proxies': nodes.map((n) => n['name']).toList(),
      });
    } else {
      groups.add({
        'name': groupName,
        'type': 'url-test',
        'url': defaultTestUrl,
        'interval': 300,
        'tolerance': 50,
        'proxies': nodes.map((n) => n['name']).toList(),
      });
    }
  }
  // 未识别地域兜底组（上游自命名无法归类时归入此处）
  byRegion.forEach((code, nodes) {
    const groupName = kFallbackRegionGroupName;
    regionGroupNames.add(groupName);
    if (_xboardLoadBalanceEnabled) {
      groups.add({
        'name': groupName,
        'type': 'load-balance',
        'strategy': 'sticky-sessions',
        'url': defaultTestUrl,
        'interval': 300,
        'proxies': nodes.map((n) => n['name']).toList(),
      });
    } else {
      groups.add({
        'name': groupName,
        'type': 'url-test',
        'url': defaultTestUrl,
        'interval': 300,
        'tolerance': 50,
        'proxies': nodes.map((n) => n['name']).toList(),
      });
    }
  });

  groups.insert(0, {
    'name': kAutoRegionGroupName,
    'type': 'url-test',
    'url': defaultTestUrl,
    'interval': 300,
    'tolerance': 50,
    'proxies': List.of(regionGroupNames),
  });
  groups.insert(1, {
    'name': kSelectorGroupName,
    'type': 'select',
    'proxies': [kAutoRegionGroupName, ...regionGroupNames],
  });

  final flatProxies = List<Map<String, dynamic>>.unmodifiable(allPatched);

  return XboardPackagedConfig(
    proxies: flatProxies,
    proxyGroups: groups,
    groupOf: nameMapping,
  );
}

String _pad(int index) => index.toString().padLeft(2, '0');

const kDefaultTestUrl = 'http://connect.rom.miui.com/generate_204';
const kAutoRegionGroupName = '自动（最优地域）';
const kSelectorGroupName = '节点选择';

/// 未识别地域兜底组名（mihomo 配置内标识，非展示文案：展示时取“优选”后缀判定）。
const kFallbackRegionGroupName = '🌐 优选';

const _passthroughTargets = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'GLOBAL',
  'COMPATIBLE',
};

/// mihomo 规则目标段定位：目标是最后一段；带 no-resolve 等参数时为倒数第二段。
(int, String) _ruleTargetIndex(String text) {
  final parts = text.split(',');
  if (parts.length <= 1) return (-1, '');
  const params = {'no-resolve', 'no-clump', 'src'};
  final last = parts.last.trim();
  if (params.contains(last.toLowerCase()) && parts.length >= 3) {
    return (parts.length - 2, parts[parts.length - 2]);
  }
  return (parts.length - 1, last);
}

/// 受管 Profile 的整配置包装（F-NODE-3）：proxies 脱敏重编 + 地域组重建 +
/// 旧规则目标重映射到 [kSelectorGroupName]；空订阅降级为最小可校验配置。
Map<String, dynamic> applyManagedPackaging(Map<String, dynamic> config) {
  final packaged = packageNodes(config);
  if (packaged == null) {
    final shell = Map<String, dynamic>.of(config)
      ..remove('proxies')
      ..remove('proxy-groups')
      ..remove('rules')
      ..remove('rule');
    return shell;
  }

  final result = Map<String, dynamic>.of(config);
  result['proxies'] = packaged.proxies;
  result['proxy-groups'] = packaged.proxyGroups;

  final oldGroupNames = <String>{
    for (final g in (config['proxy-groups'] as List? ?? []))
      if (g is Map) g['name']?.toString() ?? '',
  };
  final sanitizedNames = packaged.proxies
      .map((p) => p['name']?.toString() ?? '')
      .toSet();
  final groupNames = packaged.proxyGroups
      .map((g) => g['name']?.toString() ?? '')
      .toSet();

  final newRules = <String>[];
  var hasMatch = false;
  for (final rule in (config['rules'] as List? ?? [])) {
    final text = rule?.toString() ?? '';
    if (text.isEmpty) continue;
    final (targetIndex, target) = _ruleTargetIndex(text);
    if (targetIndex < 0) continue;
    String mapped;
    if (_passthroughTargets.contains(target)) {
      mapped = text;
    } else if (oldGroupNames.contains(target)) {
      final parts = text.split(',');
      parts[targetIndex] = kSelectorGroupName;
      mapped = parts.join(',');
    } else if (sanitizedNames.contains(target) || groupNames.contains(target)) {
      mapped = text;
    } else {
      continue;
    }
    if (mapped.startsWith('MATCH')) hasMatch = true;
    newRules.add(mapped);
  }
  if (!hasMatch) {
    newRules.add('MATCH,$kSelectorGroupName');
  }
  result['rules'] = newRules;
  result.remove('rule');
  return sanitizeDanglingRefs(result);
}

/// 清理悬空引用（fixpoint）：组引用不存在的成员、规则引用不存在的目标。
Map<String, dynamic> sanitizeDanglingRefs(Map<String, dynamic> config) {
  var current = Map<String, dynamic>.of(config);
  for (var round = 0; round < 8; round++) {
    final proxyNames = <String>{
      for (final p in (current['proxies'] as List? ?? []))
        if (p is Map) p['name']?.toString() ?? '',
    };
    final groups = (current['proxy-groups'] as List? ?? []);
    final groupNames = <String>{
      for (final g in groups)
        if (g is Map) g['name']?.toString() ?? '',
    };
    var changed = false;

    final newGroups = <Map<String, dynamic>>[];
    for (final g in groups) {
      if (g is! Map<String, dynamic>) continue;
      final rawMembers = g['proxies'] as List? ?? [];
      final members = rawMembers
          .whereType<String>()
          .where((m) => proxyNames.contains(m) || groupNames.contains(m))
          .toList();
      if (members.length != rawMembers.length) changed = true;
      if (members.isEmpty) {
        changed = true;
        continue;
      }
      newGroups.add({...g, 'proxies': members});
    }

    final validTargets = {
      ...proxyNames,
      ...newGroups.map((g) => g['name']?.toString() ?? ''),
      ..._passthroughTargets,
    };
    final newRules = <dynamic>[];
    for (final rule in (current['rules'] as List? ?? [])) {
      final text = rule?.toString() ?? '';
      final (_, target) = _ruleTargetIndex(text);
      if (validTargets.contains(target)) {
        newRules.add(rule);
      } else {
        changed = true;
      }
    }

    current = Map<String, dynamic>.of(current)
      ..['proxy-groups'] = newGroups
      ..['rules'] = newRules;
    if (!changed) break;
  }
  return current;
}

/// F-NODE-2 地域状态词档位（流畅/正常/拥挤）。
enum XboardRegionStatus { fluent, normal, congested }

/// 按探测时延映射状态词档位（PRD §3.6 F-NODE-2，阈值可配置）：
/// <200ms 流畅；<500ms 正常；其余（含超时/未连通）拥挤。
/// 远洋地区（美/欧）200ms+ 属常态，不应判拥挤。
XboardRegionStatus regionStatusForDelay(int? delay) {
  if (delay == null || delay <= 0) return XboardRegionStatus.congested;
  if (delay < 200) return XboardRegionStatus.fluent;
  if (delay < 500) return XboardRegionStatus.normal;
  return XboardRegionStatus.congested;
}
