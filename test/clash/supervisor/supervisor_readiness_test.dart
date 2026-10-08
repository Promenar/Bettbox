import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/clash/supervisor/supervisor_readiness.dart';

void main() {
  test('首次启动错误不能覆盖当前已成功重启的就绪状态', () async {
    final initial = Future<void>.error(StateError('公开首次错误'));
    expect(
      await awaitSupervisorReady(
        initial: initial,
        pending: () => null,
        ready: () => true,
      ),
      true,
    );
  });
  test('等待初始工作后仍须等待新排队的restart且以当前状态裁决', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    Future<void>? pending = first.future;
    var delivered = false;
    final waiting =
        awaitSupervisorReady(pending: () => pending, ready: () => true).then((
          value,
        ) {
          delivered = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    pending = second.future;
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(delivered, false);
    pending = null;
    second.complete();
    expect(await waiting, true);
  });
}
