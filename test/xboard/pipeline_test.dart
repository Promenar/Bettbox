
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/xboard/node_packager.dart';

Map<String, dynamic> _xboardEmptyTemplate() => {
  'mixed-port': 7890,
  'mode': 'rule',
  'log-level': 'info',
  'proxies': [],
  'proxy-groups': [
    {
      'name': 'XBoard',
      'type': 'select',
      'proxies': ['自动选择', 'DIRECT'],
    },
    {'name': '自动选择', 'type': 'url-test', 'proxies': []},
  ],
  'rules': ['MATCH,XBoard'],
};

Map<String, dynamic> _xboardNodeTemplate() => {
  'mixed-port': 7890,
  'mode': 'rule',
  'proxies': [
    {'name': '香港 IEPL 01', 'type': 'ss', 'server': '1.1.1.1', 'port': 443},
    {'name': 'HK BGP 02', 'type': 'ss', 'server': '1.1.1.2', 'port': 443},
    {'name': '🇯🇵 日本 01', 'type': 'ss', 'server': '1.1.1.3', 'port': 443},
  ],
  'proxy-groups': [
    {
      'name': 'XBoard',
      'type': 'select',
      'proxies': ['自动选择', '香港 IEPL 01'],
    },
    {'name': '自动选择', 'type': 'url-test', 'proxies': ['香港 IEPL 01']},
  ],
  'rules': [
    'DOMAIN-SUFFIX,google.com,XBoard',
    'GEOIP,CN,DIRECT',
    'MATCH,XBoard',
  ],
};

void main() {
  group('applyManagedPackaging', () {
    test('空订阅降级：移除 proxies/groups/rules，保留常规字段', () {
      final result = applyManagedPackaging(_xboardEmptyTemplate());
      expect(result.containsKey('proxies'), isFalse);
      expect(result.containsKey('proxy-groups'), isFalse);
      expect(result.containsKey('rules'), isFalse);
      expect(result['mixed-port'], 7890);
      expect(result['mode'], 'rule');
    });

    test('有节点：重建地域组并重映射旧组规则目标', () {
      final result = applyManagedPackaging(_xboardNodeTemplate());
      final proxies = (result['proxies'] as List).cast<Map>();
      final names = proxies.map((p) => p['name']).toList();
      expect(names, ['HK-01', 'HK-02', 'JP-01']);

      final groups = (result['proxy-groups'] as List).cast<Map>();
      final groupNames = groups.map((g) => g['name']).toList();
      expect(groupNames[0], kAutoRegionGroupName);
      expect(groupNames, contains('节点选择'));
      expect(groupNames, contains('🇭🇰 香港 HK'));
      expect(groupNames, contains('🇯🇵 日本 JP'));
      // 旧组名 XBoard 已不存在
      expect(groupNames.contains('XBoard'), isFalse);

      final rules = (result['rules'] as List).cast<String>();
      expect(rules, contains('DOMAIN-SUFFIX,google.com,节点选择'));
      expect(rules, contains('GEOIP,CN,DIRECT'));
      expect(rules.last, 'MATCH,节点选择');
      // 无悬空组
      expect(groupNames.contains('自动选择'), isFalse);
    });

    test('幂等：对已包装配置再包装结果稳定', () {
      final once = applyManagedPackaging(_xboardNodeTemplate());
      final twice = applyManagedPackaging(once);
      expect(twice['proxies'].toString(), once['proxies'].toString());
      expect(twice['proxy-groups'].toString(), once['proxy-groups'].toString());
      expect(twice['rules'].toString(), once['rules'].toString());
    });
  });

  group('sanitizeDanglingRefs', () {
    test('剔除悬空组成员与悬空规则', () {
      final result = sanitizeDanglingRefs({
        'proxies': [
          {'name': 'a', 'type': 'ss'},
        ],
        'proxy-groups': [
          {'name': 'g1', 'type': 'select', 'proxies': ['a', 'ghost']},
          {'name': 'g2', 'type': 'select', 'proxies': ['ghost']},
        ],
        'rules': [
          'DOMAIN,a.com,g1',
          'DOMAIN,b.com,g2',
          'DOMAIN,c.com,ghost',
        ],
      });
      final groups = (result['proxy-groups'] as List).cast<Map>();
      expect(groups.length, 1);
      expect(groups.first['name'], 'g1');
      expect(groups.first['proxies'], ['a']);
      expect(result['rules'], ['DOMAIN,a.com,g1']);
    });
  });
}
