import 'dart:async';
import 'package:bett_box/clash/native_action_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('成功回包关闭实际ReceivePort，迟到回包不能改变终态', () async {
    final request = NativeActionRequest(timeout: const Duration(seconds: 1));
    request.send((port) {
      port.send('公开完成');
      port.send('公开迟到');
    });
    expect(await request.result, '公开完成');
    await request.closed.timeout(const Duration(seconds: 1));
  });
  test('无回包截止时间关闭实际ReceivePort', () async {
    final request = NativeActionRequest(
      timeout: const Duration(milliseconds: 10),
    );
    request.send((_) {});
    await expectLater(request.result, throwsA(isA<TimeoutException>()));
    await request.closed.timeout(const Duration(seconds: 1));
  });
  test('发送异常及错误类型回包关闭实际ReceivePort', () async {
    final failed = NativeActionRequest();
    failed.send((_) => throw StateError('公开发送错误'));
    await expectLater(failed.result, throwsStateError);
    await failed.closed.timeout(const Duration(seconds: 1));
    final invalid = NativeActionRequest();
    invalid.send((port) => port.send(123));
    await expectLater(invalid.result, throwsStateError);
    await invalid.closed.timeout(const Duration(seconds: 1));
  });
}
