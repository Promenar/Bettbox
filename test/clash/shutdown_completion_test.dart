import 'dart:async';

import 'package:bett_box/clash/shutdown_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('关闭失败保留引擎', () async {
    var destroyed = false;
    expect(await completeShutdown(close: () async => false, destroy: () {
      destroyed = true;
      return true;
    }), isFalse);
    expect(destroyed, isFalse);
  });

  test('关闭错误保留引擎并传递错误', () async {
    var destroyed = false;
    await expectLater(completeShutdown(close: () async => throw StateError('公开关闭失败'), destroy: () {
      destroyed = true;
      return true;
    }), throwsStateError);
    expect(destroyed, isFalse);
  });

  test('先确认关闭再等待销毁回执', () async {
    final closed = Completer<bool>();
    final destroyed = Completer<bool>();
    final entered = Completer<void>();
    var complete = false;
    final pending = completeShutdown(close: () => closed.future, destroy: () {
      entered.complete();
      return destroyed.future;
    }).then((value) { complete = true; return value; });
    expect(entered.isCompleted, isFalse);
    closed.complete(true);
    await entered.future;
    expect(complete, isFalse);
    destroyed.complete(false);
    expect(await pending, isFalse);
  });

  test('销毁确认才发布成功', () async {
    expect(await completeShutdown(close: () async => true, destroy: () async => true), isTrue);
  });

  test('销毁异常不发布成功且只调用一次', () async {
    var calls = 0;
    await expectLater(completeShutdown(close: () async => true, destroy: () {
      calls++;
      throw StateError('公开销毁失败');
    }), throwsStateError);
    expect(calls, 1);
  });
}
