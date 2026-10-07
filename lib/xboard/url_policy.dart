/// 面板与引导源仅接受无内嵌认证的 HTTPS 地址。
Uri? publicHttpsUri(String value) {
  if (value != value.trim() || RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port <= 0 ||
      uri.port > 65535) {
    return null;
  }
  return uri;
}

/// API 入口只能是源站根地址，避免路径与查询改写鉴权请求。
String? normalizePanelOrigin(String value) {
  final uri = publicHttpsUri(value);
  if (uri == null || uri.hasQuery || (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  return uri.replace(path: '').toString();
}
