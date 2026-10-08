import 'dart:convert';
import 'package:bett_box/clash/android_runtime_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FFI耗时后JNI只使用剩余总预算', () async {
    var nativeEntered = false;
    final passed = await confirmAndroidRuntimeIdentity(
      requestId: 'budget-runtime',
      timeout: const Duration(milliseconds: 100),
      invokeGo: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return jsonEncode({
          'id': 'budget-runtime',
          'method': 'getAndroidOwnedConfigStatus',
          'code': 0,
          'data': jsonEncode({
            'epoch': 2,
            'blocked': false,
            'outcome': 'rejected',
          }),
        });
      },
      invokeNative: (_) async {
        nativeEntered = true;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return true;
      },
    );
    expect(nativeEntered, isTrue);
    expect(passed, isFalse);
  });
  test('无等待预算不进入任何原生通道', () async {
    var invoked = false;
    expect(
      await confirmAndroidRuntimeIdentity(
        requestId: 'empty-budget',
        timeout: Duration.zero,
        invokeGo: (_) async {
          invoked = true;
          return '';
        },
        invokeNative: (_) async {
          invoked = true;
          return true;
        },
      ),
      isFalse,
    );
    expect(invoked, isFalse);
  });
  Map<String, dynamic> status({Object? epoch = 2, bool blocked = false}) => {
    'outcome': 'rejected',
    'phase': 'notEntered',
    'epoch': epoch,
    'configRevision': 0,
    'attemptedRevision': 0,
    'stateGeneration': 0,
    'configured': false,
    'blocked': blocked,
    'options': null,
    'errorCode': 'unconfigured',
  };
  Map<String, dynamic> frame(Map<String, dynamic> value) => {
    'id': 'public-runtime',
    'method': 'getAndroidOwnedConfigStatus',
    'code': 0,
    'data': jsonEncode(value),
  };
  test('实际请求关联后仅向JNI发送精确整数实例身份', () async {
    expect(
      await confirmAndroidRuntimeIdentity(
        requestId: 'public-runtime',
        invokeGo: (request) async {
          expect(jsonDecode(request), {
            'id': 'public-runtime',
            'method': 'getAndroidOwnedConfigStatus',
            'data': null,
          });
          return jsonEncode(frame(status(epoch: 9007199254740991)));
        },
        invokeNative: (epoch) async {
          expect(epoch, 9007199254740991);
          return true;
        },
      ),
      isTrue,
    );
  });
  test('旧关联、错误代码、非法身份和阻断状态不进入JNI验证', () async {
    final valid = frame(status());
    final invalid = [
      {...valid, 'id': 'older-runtime'},
      {...valid, 'method': 'getIsInit'},
      {...valid, 'code': -1},
      {...valid, 'code': 0.0},
      {...valid, 'data': status()},
      for (final epoch in [null, 0, 1, -1, '2', 2.0, 9007199254740992])
        frame(status(epoch: epoch)),
      frame(status(blocked: true)),
      frame({...status(), 'outcome': 'unknown'}),
      null,
      [],
    ];
    for (final reply in invalid) {
      var called = false;
      expect(
        await confirmAndroidRuntimeIdentity(
          requestId: 'public-runtime',
          invokeGo: (_) async => jsonEncode(reply),
          invokeNative: (_) async {
            called = true;
            return true;
          },
        ),
        isFalse,
      );
      expect(called, isFalse);
    }
  });
  test('JNI不匹配、空结果、异常和畸形FFI回包不能确认', () async {
    for (final native in [false, null]) {
      expect(
        await confirmAndroidRuntimeIdentity(
          requestId: 'public-runtime',
          invokeGo: (_) async => jsonEncode(frame(status())),
          invokeNative: (_) async => native,
        ),
        isFalse,
      );
    }
    expect(
      await confirmAndroidRuntimeIdentity(
        requestId: 'public-runtime',
        invokeGo: (_) async => jsonEncode(frame(status())),
        invokeNative: (_) async => throw StateError('公开JNI错误'),
      ),
      isFalse,
    );
    expect(
      await confirmAndroidRuntimeIdentity(
        requestId: 'public-runtime',
        invokeGo: (_) async => '{',
        invokeNative: (_) async => true,
      ),
      isFalse,
    );
    expect(
      await confirmAndroidRuntimeIdentity(
        requestId: 'public-runtime',
        invokeGo: (_) async => throw StateError('公开FFI错误'),
        invokeNative: (_) async => true,
      ),
      isFalse,
    );
  });
}
