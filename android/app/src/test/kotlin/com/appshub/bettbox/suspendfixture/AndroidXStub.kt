package androidx.core.content

import android.content.Context
import android.os.PowerManager

inline fun <reified T : Any> Context.getSystemService(): T? =
    if (T::class == PowerManager::class) powerManager as T else null
