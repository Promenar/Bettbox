import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 本机开发服务与正式默认服务分离，不迁移或批量删除正式条目。
const localMacOSKeychainOptions = MacOsOptions(
  accountName: 'com.appshub.bettbox.local-development.xboard',
  usesDataProtectionKeychain: false,
  synchronizable: false,
);

bool validateLocalMacOSStorageBuild({
  required bool enabled,
  required bool isMacOS,
  required String channel,
}) {
  if (!enabled) return false;
  if (!isMacOS || channel != 'local-macos-development') {
    throw StateError('LOCAL_MACOS_KEYCHAIN_BUILD_NOT_AUTHORIZED');
  }
  return true;
}

abstract interface class XboardStorageBackend {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

class PluginXboardStorage implements XboardStorageBackend {
  const PluginXboardStorage(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

class LocalMacOSXboardStorage extends PluginXboardStorage {
  LocalMacOSXboardStorage({FlutterSecureStorage? storage})
    : super(
        storage ??
            const FlutterSecureStorage(mOptions: localMacOSKeychainOptions),
      );

  @override
  Future<void> delete({required String key}) async {
    try {
      await super.delete(key: key);
    } on PlatformException catch (error) {
      // 仅归一化锁定插件的同步删除权利错误；同一开发条目必须确已不存在。
      if (error.code != 'Unexpected security result code' ||
          error.details is! int ||
          error.details != -34018) {
        rethrow;
      }
      if (await super.read(key: key) != null) rethrow;
      return;
    }
    if (await super.read(key: key) != null) {
      throw StateError('LOCAL_KEYCHAIN_DELETE_UNCONFIRMED');
    }
  }
}

XboardStorageBackend xboardStorageForBuild({FlutterSecureStorage? storage}) {
  final local = validateLocalMacOSStorageBuild(
    enabled: const bool.fromEnvironment('BETTBOX_MACOS_DEVELOPMENT_KEYCHAIN'),
    isMacOS: Platform.isMacOS,
    channel: const String.fromEnvironment('APP_ENV'),
  );
  return local
      ? LocalMacOSXboardStorage(storage: storage)
      : PluginXboardStorage(storage ?? const FlutterSecureStorage());
}
