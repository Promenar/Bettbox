import 'package:bett_box/xboard/secure_store.dart';
import 'package:bett_box/xboard/storage_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class PublicStorageFixture extends FlutterSecureStorage {
  PublicStorageFixture();
  final values = <String, String>{};
  Object? readError;
  Object? deleteError;
  bool keepAfterDelete = false;
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (readError case final error?) {
      throw error;
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (deleteError case final error?) {
      throw error;
    }
    if (!values.containsKey(key)) {
      throw PlatformException(
        code: 'Unexpected security result code',
        details: -34018,
      );
    }
    if (!keepAfterDelete) values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('开发准入拒绝错误平台和构建标记', () {
    for (final mac in [false, true]) {
      expect(
        validateLocalMacOSStorageBuild(
          enabled: false,
          isMacOS: mac,
          channel: 'stable',
        ),
        isFalse,
      );
    }
    expect(
      validateLocalMacOSStorageBuild(
        enabled: true,
        isMacOS: true,
        channel: 'local-macos-development',
      ),
      isTrue,
    );
    for (final entry in [
      (false, 'local-macos-development'),
      (true, 'stable'),
      (true, 'pre'),
    ]) {
      expect(
        () => validateLocalMacOSStorageBuild(
          enabled: true,
          isMacOS: entry.$1,
          channel: entry.$2,
        ),
        throwsStateError,
      );
    }
  });
  test('开发服务固定且与正式服务分离', () {
    expect(
      localMacOSKeychainOptions.accountName,
      isNot(AppleOptions.defaultAccountName),
    );
    expect(
      localMacOSKeychainOptions.accountName,
      'com.appshub.bettbox.local-development.xboard',
    );
    expect(localMacOSKeychainOptions.usesDataProtectionKeychain, isFalse);
    expect(localMacOSKeychainOptions.synchronizable, isFalse);
    expect(const MacOsOptions().usesDataProtectionKeychain, isTrue);
  });
  test('已删除条目仍存在时不得确认', () async {
    final plugin = PublicStorageFixture()
      ..values['public-key'] = 'public-value'
      ..keepAfterDelete = true;
    await expectLater(
      LocalMacOSXboardStorage(storage: plugin).delete(key: 'public-key'),
      throwsStateError,
    );
    expect(plugin.values['public-key'], 'public-value');
  });
  test('指定权利错误在条目仍存在时传播原错误', () async {
    final error = PlatformException(
      code: 'Unexpected security result code',
      details: -34018,
    );
    final plugin = PublicStorageFixture()
      ..values['public-key'] = 'public-value'
      ..deleteError = error;
    await expectLater(
      LocalMacOSXboardStorage(storage: plugin).delete(key: 'public-key'),
      throwsA(same(error)),
    );
  });
  test('归一化前的读取失败不得成为删除确认', () async {
    final error = PlatformException(code: 'PUBLIC_READ_FAILURE');
    final plugin = PublicStorageFixture()..readError = error;
    await expectLater(
      LocalMacOSXboardStorage(storage: plugin).delete(key: 'public-key'),
      throwsA(same(error)),
    );
  });
  test('其它错误或非整数状态不触发缺失核验', () async {
    for (final error in [
      PlatformException(code: 'OTHER', details: -34018),
      PlatformException(
        code: 'Unexpected security result code',
        details: '-34018',
      ),
      PlatformException(
        code: 'Unexpected security result code',
        details: -25308,
      ),
    ]) {
      final plugin = PublicStorageFixture()..deleteError = error;
      await expectLater(
        LocalMacOSXboardStorage(storage: plugin).delete(key: 'public-key'),
        throwsA(same(error)),
      );
      expect(plugin.reads, 0);
    }
  });
  test('本机开发会话重复清理确认同一命名空间已不存在', () async {
    final storage = PublicStorageFixture();
    final store = XboardSecureStore(storage: storage);
    await store.saveSession(
      authData: 'public-synthetic-session',
      email: 'public@example.invalid',
    );
    await store.clearSession();
    const local = bool.fromEnvironment('BETTBOX_MACOS_DEVELOPMENT_KEYCHAIN');
    if (local) {
      await expectLater(store.clearSession(), completes);
      expect(await store.readSession(), isNull);
    } else {
      await expectLater(
        store.clearSession(),
        throwsA(isA<PlatformException>()),
      );
    }
  });
}
