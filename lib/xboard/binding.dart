/// 受管订阅绑定（F-SUB-1 / F-DOMAIN-5）。
///
/// 登录后把服务端下发的 `subscribe_url` 绑定为一条"受管 Profile"：
/// 用户不可编辑，域名切换/重置订阅时仅替换 URL 并静默更新。
library;

import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';

const _managedAutoUpdateDuration = Duration(hours: 6);

Profile? findManagedProfile() {
  for (final profile in globalState.config.profiles) {
    if (profile.managed) {
      return profile;
    }
  }
  return null;
}

/// 同步受管 Profile：不存在则创建并返回新 Profile；存在则替换 URL/label 更新。
///
/// 受管 Profile 允许降级创建：`validate: false` 跳过订阅保存期校验
/// （面板空订阅/悬空组模板会导致校验失败）。配置在应用期经
/// applyManagedPackaging 清理后才交给内核（state.dart getProfileConfig 挂点）。
Future<Profile> syncManagedSubscription({
  required String subscribeUrl,
  required String planName,
}) async {
  debugPrint('[XBOARD_BINDING] sync start: $subscribeUrl');
  final managed = findManagedProfile();
  if (managed == null) {
    final fresh = Profile.normal(
      label: planName,
      url: subscribeUrl,
    ).copyWith(managed: true, autoUpdateDuration: _managedAutoUpdateDuration);
    final updated = await fresh.update(validate: false);
    debugPrint('[XBOARD_BINDING] created profile ${updated.id}');
    await globalState.appController.addProfile(updated);
    return updated;
  }
  if (managed.url == subscribeUrl && managed.label == planName) {
    return managed;
  }
  final changed = managed.copyWith(url: subscribeUrl, label: planName);
  final updated = await changed.update(validate: false);
  debugPrint('[XBOARD_BINDING] updated profile ${updated.id}');
  await globalState.appController.updateProfile(updated);
  return updated;
}

/// 重新下载受管订阅内容（节点/规则变更时刷新本地配置文件）。
Future<void> refreshManagedSubscription() async {
  final managed = findManagedProfile();
  if (managed == null) return;
  final updated = await managed.update(validate: false);
  await globalState.appController.updateProfile(updated);
  debugPrint('[XBOARD_BINDING] refreshed profile ${updated.id}');
}

/// F-DOMAIN-5：把受管订阅 URL 的 host/scheme/port 替换为新入口域名
/// （path/query/fragment 保持原样），host 未变时原样返回。
Uri rewriteHost(Uri url, Uri base) {
  if (url.host == base.host && url.port == base.port && url.scheme == base.scheme) {
    return url;
  }
  return url.replace(
    scheme: base.scheme,
    host: base.host,
    port: base.port,
  );
}

/// 域名切换生效时改写受管 Profile URL 并刷新订阅；返回是否发生改写。
Future<bool> applyManagedDomainHost(String baseUrl) async {
  final managed = findManagedProfile();
  if (managed == null) return false;
  final base = Uri.parse(baseUrl);
  final rewritten = rewriteHost(Uri.parse(managed.url), base);
  if (rewritten.toString() == managed.url) return false;
  final changed = managed.copyWith(url: rewritten.toString());
  final updated = await changed.update(validate: false);
  await globalState.appController.updateProfile(updated);
  debugPrint('[XBOARD_BINDING] domain host rewritten for profile ${updated.id}');
  return true;
}
