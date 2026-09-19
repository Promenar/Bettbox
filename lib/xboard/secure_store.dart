/// 凭据安全存储（F-AUTH-5）：token/auth_data 存系统安全存储，
/// 禁止落入 SharedPreferences 明文。Android Keystore / macOS Keychain /
/// Windows DPAPI / Linux libsecret 由 flutter_secure_storage 平台实现承担。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class XboardSecureStore {
  XboardSecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyAuthData = 'xboard_auth_data';
  static const _keyEmail = 'xboard_email';
  static const _keyDomainPool = 'xboard_domain_pool';
  static const _keyRegionCatalog = 'xboard_region_catalog';
  static const _keyAnnouncementUrl = 'xboard_announcement_url';
  static const _keyLoadBalance = 'xboard_load_balance';

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

  /// 域名池持久化（F-DOMAIN-3：引导源下发后冷启动直接使用新域名）。
  Future<void> saveDomainPool({
    required List<String> domains,
    required List<String> sources,
  }) async {
    await _storage.write(
      key: _keyDomainPool,
      value: jsonEncode({'domains': domains, 'sources': sources}),
    );
  }

  Future<({List<String> domains, List<String> sources})?> readDomainPool() async {
    final raw = await _storage.read(key: _keyDomainPool);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        final domains = _stringList(json['domains']);
        if (domains.isEmpty) return null;
        return (domains: domains, sources: _stringList(json['sources']));
      }
      // 兼容早期仅存列表的格式
      if (json is List) {
        final domains = _stringList(json);
        if (domains.isEmpty) return null;
        return (domains: domains, sources: <String>[]);
      }
    } catch (_) {}
    return null;
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> saveRegionCatalog(List<dynamic> raw) async {
    await _storage.write(key: _keyRegionCatalog, value: jsonEncode(raw));
  }

  Future<List<dynamic>?> readRegionCatalog() async {
    final raw = await _storage.read(key: _keyRegionCatalog);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {}
    return null;
  }

  Future<void> saveAnnouncementUrl(String url) async {
    await _storage.write(key: _keyAnnouncementUrl, value: url);
  }

  Future<String?> readAnnouncementUrl() async {
    return _storage.read(key: _keyAnnouncementUrl);
  }

  Future<void> saveLoadBalance(bool enabled) async {
    await _storage.write(key: _keyLoadBalance, value: enabled ? '1' : '0');
  }

  Future<bool?> readLoadBalance() async {
    final v = await _storage.read(key: _keyLoadBalance);
    if (v == null) return null;
    return v == '1' || v == 'true';
  }
}
