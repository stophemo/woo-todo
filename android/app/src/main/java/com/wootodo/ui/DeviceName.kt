package com.wootodo.ui

import android.content.Context
import android.os.Build
import android.provider.Settings
import com.wootodo.R
import java.util.Locale

/** 服务端设备列表里显示的当前设备名称。 */
object DeviceName {
    fun current(context: Context): String {
        val configured = runCatching {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        }.getOrNull()?.trim()
        if (!configured.isNullOrBlank() && configured.length <= 80) {
            return configured
        }
        val manufacturer = Build.MANUFACTURER.trim().replaceFirstChar {
            if (it.isLowerCase()) it.titlecase(Locale.getDefault()) else it.toString()
        }
        val model = Build.MODEL.trim()
        return listOf(manufacturer, model)
            .filter { it.isNotBlank() }
            .distinctBy { it.lowercase() }
            .joinToString(" ")
            .ifBlank { context.getString(R.string.android_device_name) }
    }
}
