package com.wootodo.ui

import android.content.Context
import android.os.Build
import com.wootodo.R

/** 服务端设备列表里显示的当前设备名称。 */
object DeviceName {
    fun current(context: Context): String {
        val manufacturer = Build.MANUFACTURER.trim()
        val model = Build.MODEL.trim()
        return listOf(manufacturer, model)
            .filter { it.isNotBlank() }
            .distinctBy { it.lowercase() }
            .joinToString(" ")
            .ifBlank { context.getString(R.string.android_device_name) }
    }
}
