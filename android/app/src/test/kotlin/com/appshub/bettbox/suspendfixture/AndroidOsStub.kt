package android.os

object Build {
    object VERSION {
        var SDK_INT = 23
    }

    object VERSION_CODES {
        const val M = 23
    }
}

class PowerManager {
    var isInteractive = true
    var isDeviceIdleMode = false

    companion object {
        const val ACTION_DEVICE_IDLE_MODE_CHANGED = "android.os.action.DEVICE_IDLE_MODE_CHANGED"
    }
}
