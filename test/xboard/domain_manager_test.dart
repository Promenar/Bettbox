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
}
