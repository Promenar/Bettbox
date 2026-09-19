import 'package:bett_box/xboard/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('refreshSubscriptionCycle（SaaS 自动更新）', () {
    test('未登录态直接返回：不抛错、不改状态（登出冻结）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(xboardSessionProvider).isAuthenticated,
        isFalse,
      );
      await container
          .read(xboardSessionProvider.notifier)
          .refreshSubscriptionCycle(force: true);
      expect(
        container.read(xboardSessionProvider).status,
        SessionStatus.restoring,
      );
      expect(
        container.read(xboardSessionProvider).refreshedAt,
        isNull,
      );
    });

    test('地域目录默认值为空（不影响冻结判定）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(xboardRegionCatalogProvider).isEmpty,
        isTrue,
      );
    });
  });
}
