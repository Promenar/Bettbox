package com.appshub.bettbox.plugins

object VpnPlugin {
    var networkUpdates = 0
        private set

    fun reset() {
        networkUpdates = 0
    }

    fun onUpdateNetwork() {
        networkUpdates += 1
    }
}
