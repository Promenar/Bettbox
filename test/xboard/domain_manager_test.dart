import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/xboard/domain_manager.dart';

void main() {
  test('默认域名池与活跃域名', () {
    final manager = XboardDomainManager();
    expect(manager.domains, XboardDomainManager.defaultDomains);
    expect(manager.active, XboardDomainManager.defaultDomains.first);
    expect(manager.rotateNext(), isFalse, reason: '单域名池不轮换');
  });

  test('连续失败达到阈值后轮换到下一候选', () {
    final manager = XboardDomainManager(
      domains: ['https://a.example.com', 'https://b.example.com', 'https://c.example.com'],
    );
    manager.reportConnectionFailure();
    expect(manager.active, 'https://a.example.com');
    manager.reportConnectionFailure();
    expect(manager.active, 'https://b.example.com');
    expect(manager.activeFailureCount, 0);
  });

  test('成功清零失败计数', () {
    final manager = XboardDomainManager(domains: ['https://a.example.com']);
    manager.reportConnectionFailure();
    expect(manager.activeFailureCount, 1);
    manager.reportSuccess();
    expect(manager.activeFailureCount, 0);
    expect(manager.allDomainsFailing, isFalse);
  });

  test('全池失败判定', () {
    final manager = XboardDomainManager(
      domains: ['https://a.example.com', 'https://b.example.com'],
    );
    // a 连续失败两次 → 轮换到 b；再失败两次 → 全池失败
    manager
      ..reportConnectionFailure()
      ..reportConnectionFailure()
      ..reportConnectionFailure()
      ..reportConnectionFailure();
    expect(manager.allDomainsFailing, isTrue);
  });

  test('updatePool 合并引导源域名且活跃域名被退役时切走', () {
    final manager = XboardDomainManager(
      domains: ['https://a.example.com', 'https://b.example.com'],
    );
    manager.reportConnectionFailure(); // a 失败 1 次
    manager.updatePool(['https://b.example.com', 'https://c.example.com']);
    expect(
      manager.domains,
      containsAll(['https://a.example.com', 'https://b.example.com', 'https://c.example.com']),
    );
    expect(manager.domains.first, 'https://b.example.com', reason: '引导源列表排前');
    expect(manager.active, 'https://b.example.com', reason: 'a 不在引导源列表（退役）→ 切到列表首域名');
    manager.updatePool(['https://c.example.com', 'https://d.example.com']);
    expect(manager.active, 'https://c.example.com', reason: '活跃域名 b 被退役则切到新列表首域名');
    expect(manager.domains, contains('https://a.example.com'), reason: '旧域名保留为轮换备选');
  });

  test('updatePool 触发持久化钩子', () {
    final persisted = <String>[];
    final manager = XboardDomainManager(domains: ['https://a.example.com']);
    manager.onPoolChanged = (domains) async {
      persisted.addAll(domains);
    };
    manager.updatePool(['https://b.example.com']);
    expect(persisted, containsAll(['https://a.example.com', 'https://b.example.com']));
  });

  test('addDomain 校验并切换（救援手动输入）', () {
    final manager = XboardDomainManager(domains: ['https://a.example.com']);
    expect(manager.addDomain('ftp://bad'), isFalse);
    expect(manager.addDomain('not-a-url'), isFalse);
    expect(manager.addDomain('https://backup.example.com'), isTrue);
    expect(manager.active, 'https://backup.example.com');
    // 已存在域名只切换不重复加
    final size = manager.domains.length;
    expect(manager.addDomain('https://backup.example.com'), isTrue);
    expect(manager.domains.length, size);
  });

  test('resetFailures 清空计数（救援重试）', () {
    final manager = XboardDomainManager(
      domains: ['https://a.example.com', 'https://b.example.com'],
    );
    manager
      ..reportConnectionFailure()
      ..reportConnectionFailure()
      ..reportConnectionFailure()
      ..reportConnectionFailure();
    expect(manager.allDomainsFailing, isTrue);
    manager.resetFailures();
    expect(manager.allDomainsFailing, isFalse);
  });
}
