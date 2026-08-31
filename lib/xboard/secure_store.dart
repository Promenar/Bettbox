/// 凭据安全存储（F-AUTH-5）：token/auth_data 存系统安全存储，
/// 禁止落入 SharedPreferences 明文。Android Keystore / macOS Keychain /
/// Windows DPAPI / Linux libsecret 由 flutter_secure_storage 平台实现承担。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class XboardSecureStore {
  XboardSecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyAuthData = 'xboard_auth_data';
  static const _keyEmail = 'xboard_email';

  final FlutterSecureStorage _storage;

  Future<void> saveSession({required String authData, required String email}) async {
    await _storage.write(key: _keyAuthData, value: authData);
    await _storage.write(key: _keyEmail, value: email);
  }

  Future<({String authData, String email})?> readSession() async {
    final authData = await _storage.read(key: _keyAuthData);
    final email = await _storage.read(key: _keyEmail);
    if (authData == null || authData.isEmpty || email == null) return null;
    return (authData: authData, email: email);
  }

  Future<void> clearSession() async {
    await _storage.delete(key: _keyAuthData);
    await _storage.delete(key: _keyEmail);
  }
}
