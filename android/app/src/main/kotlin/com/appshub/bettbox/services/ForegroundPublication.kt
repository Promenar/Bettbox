package com.appshub.bettbox.services

// 首次前台发布的共同入口；速度通知是否完成由发布器报告。
internal suspend fun confirmInitialForeground(
    preferSpeed: Boolean,
    publishSpeed: suspend () -> Boolean,
    publishBasic: suspend () -> Boolean
): Boolean {
    if (preferSpeed && publishSpeed()) return true
    // 速度通知被熄屏抑制或未提交时，首次基础前台仍须完成。
    return publishBasic()
}
