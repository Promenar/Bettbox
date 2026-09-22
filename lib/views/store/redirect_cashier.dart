import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Android 支持嵌入式收银台，桌面使用系统浏览器。
class RedirectCashier extends StatefulWidget {
  const RedirectCashier({super.key, required this.url});

  final String url;

  @override
  State<RedirectCashier> createState() => _RedirectCashierState();
}

class _RedirectCashierState extends State<RedirectCashier> {
  WebViewController? _controller;
  bool _embeddingFailed = false;
  bool _opening = false;
  int _generation = 0;

  bool get _embedded =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Uri? get _uri {
    final value = Uri.tryParse(widget.url);
    if (value == null ||
        value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty) {
      return null;
    }
    return value;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(RedirectCashier oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _controller = null;
      _embeddingFailed = false;
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    final uri = _uri;
    if (!_embedded || uri == null) return;
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.loadRequest(uri);
      if (mounted && generation == _generation) {
        setState(() => _controller = controller);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _embeddingFailed = true);
      }
    }
  }

  Future<void> _open() async {
    final uri = _uri;
    if (_opening || uri == null) return;
    setState(() => _opening = true);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('收银台打开失败');
      }
    } catch (_) {
      if (mounted) context.showSnackBar(appLocalizations.xbOpenCashierFailed);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_uri == null) return Text(appLocalizations.xbOpenCashierFailed);
    return Column(
      children: [
        FilledButton.tonal(
          onPressed: _opening ? null : _open,
          child: Text(appLocalizations.xbOpenCashier),
        ),
        if (_embedded) ...[
          const SizedBox(height: 12),
          if (_embeddingFailed)
            Text(appLocalizations.xbOpenCashierFailed)
          else if (_controller == null)
            const Center(child: CircularProgressIndicator())
          else
            SizedBox(
              height: 420,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: WebViewWidget(controller: _controller!),
              ),
            ),
        ],
      ],
    );
  }
}
