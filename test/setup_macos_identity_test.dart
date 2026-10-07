import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../setup.dart' as setup;

void main() {
  Map<String, dynamic> identity() => {
    'schema': 1,
    'sha256': 'a' * 64,
    'identifier': 'com.appshub.bettbox.core',
    'cdhash': 'b' * 40,
    'signingmode': 'adhoc',
  };

  test('标准身份只允许固定准备命令，未接线开发变体立即拒绝', () {
    expect(setup.macosCoreIdentityPreparationCommand(isDev: false), [
      'python3',
      'scripts/macos_core_identity.py',
      '--prepare',
    ]);
    expect(
      () => setup.macosCoreIdentityPreparationCommand(isDev: true),
      throwsStateError,
    );
  });

  test('SHA 来自已完成签名的严格公开身份结果', () {
    expect(
      setup.macosCoreIdentityShaFromOutput(jsonEncode(identity())),
      'a' * 64,
    );
    for (final change in <String, dynamic>{
      'schema': 1.0,
      'sha256': 'A' * 64,
      'identifier': 'other',
      'cdhash': 'b' * 39,
      'signingmode': 'developer-id',
    }.entries) {
      final candidate = identity()..[change.key] = change.value;
      expect(
        () => setup.macosCoreIdentityShaFromOutput(jsonEncode(candidate)),
        throwsStateError,
        reason: change.key,
      );
    }
  });

  test('多余字段、非法或超长输出仅返回固定错误', () {
    final extra = identity()..['diagnostic'] = 'PUBLIC_DIAGNOSTIC';
    final newline = identity()..['sha256'] = '${'a' * 64}\n';
    for (final input in [
      jsonEncode(extra),
      jsonEncode(newline),
      'PUBLIC_INVALID_JSON',
      'x' * 4097,
    ]) {
      expect(
        () => setup.macosCoreIdentityShaFromOutput(input),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            '固定错误',
            'macOS 内核身份准备结果无效',
          ),
        ),
      );
    }
  });
}
