/// 引导配置源客户端（F-DOMAIN-3）。
///
/// 引导源 JSON（schema 见 docs/PRD.md §6.3）承载当前有效 API 域名列表等
/// 自愈信息；多源冗余由调用方按顺序传入，本类取第一个通过校验的文档。
/// 纯 Dart，可单测。
library;

import 'package:dio/dio.dart';

/// 引导源文档（§6.3 子集：域名池切换所需字段；公告/地域目录后续里程碑消费）。
class XboardBootstrapDoc {
  const XboardBootstrapDoc({
    required this.apiDomains,
    this.bootstrapSources = const [],
    this.dnsTxtHint = '',
    this.minAppVersion = 0,
    this.announcementUrl = '',
    this.regionCatalogRaw = const [],
  });

  /// 当前有效 API 域名列表（https/http 绝对地址，去重保序）。
  final List<String> apiDomains;
  final List<String> bootstrapSources;
  final String dnsTxtHint;
  final int minAppVersion;
  final String announcementUrl;
  final List<dynamic> regionCatalogRaw;

  /// 解析失败或不可用时返回 null（供上层回退下一源）。
  static XboardBootstrapDoc? tryParse(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final list = json['api_domains'];
    if (list is! List || list.isEmpty) return null;
    final domains = <String>[];
    for (final entry in list) {
      final url = entry?.toString().trim() ?? '';
      if (_isHttpUrl(url) && !domains.contains(url)) {
        domains.add(url);
      }
    }
    if (domains.isEmpty) return null;

    final sources = <String>[];
    final rawSources = json['bootstrap_sources'];
    if (rawSources is List) {
      for (final entry in rawSources) {
        final url = entry?.toString().trim() ?? '';
        if (_isHttpUrl(url) && !sources.contains(url)) {
          sources.add(url);
        }
      }
    }

    final catalogRaw = json['region_catalog'];
    return XboardBootstrapDoc(
      apiDomains: domains,
      bootstrapSources: sources,
      dnsTxtHint: json['dns_txt_hint']?.toString() ?? '',
      minAppVersion: json['min_app_version'] is num
          ? (json['min_app_version'] as num).toInt()
          : 0,
      announcementUrl: json['announcement_url']?.toString() ?? '',
      regionCatalogRaw: catalogRaw is List ? catalogRaw : const [],
    );
  }

  static bool _isHttpUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');
}

/// 引导源拉取：按顺序尝试 [sources]，全部失败返回 null（错误只记入 [onError]）。
class XboardBootstrapClient {
  XboardBootstrapClient({Dio? dio, this.timeout = const Duration(seconds: 6)})
    : _dio = dio ?? Dio();

  final Dio _dio;
  final Duration timeout;

  Future<XboardBootstrapDoc?> fetch(
    List<String> sources, {
    void Function(String source, Object error)? onError,
  }) async {
    for (final source in sources) {
      try {
        final response = await _dio.getUri<dynamic>(
          Uri.parse(source),
          options: Options(
            connectTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (_) => true,
            headers: {'Accept': 'application/json'},
          ),
        );
        if (response.statusCode != 200) {
          onError?.call(source, 'HTTP ${response.statusCode}');
          continue;
        }
        final doc = XboardBootstrapDoc.tryParse(response.data);
        if (doc == null) {
          onError?.call(source, 'invalid schema');
          continue;
        }
        return doc;
      } catch (error) {
        onError?.call(source, error);
      }
    }
    return null;
  }
}

/// 内置引导源列表：面板同源 `/bootstrap.json` 作为开发期默认；
/// 运营侧就绪后在引导源 JSON 的 `bootstrap_sources` 中固化独立冗余源
/// （CF Workers / 备用域名 / DNS TXT，见 PRD §6.5-1）。
List<String> builtinBootstrapSources(List<String> panelDomains) =>
    panelDomains.map((d) => '$d/bootstrap.json').toList();
