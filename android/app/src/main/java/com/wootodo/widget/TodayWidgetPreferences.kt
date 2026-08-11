package com.wootodo.widget

import android.content.Context
import androidx.core.content.edit

object TodayWidgetPreferences {
    const val DEFAULT_BACKGROUND_OPACITY = 70
    private const val FILE_NAME = "today_widget_preferences"
    private const val KEY_BACKGROUND_OPACITY = "background_opacity"

    fun loadBackgroundOpacity(context: Context): Int = normalizeBackgroundOpacity(
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .getInt(KEY_BACKGROUND_OPACITY, DEFAULT_BACKGROUND_OPACITY),
    )

    fun saveBackgroundOpacity(context: Context, opacity: Int) {
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit {
                putInt(KEY_BACKGROUND_OPACITY, normalizeBackgroundOpacity(opacity))
            }
    }

    internal fun normalizeBackgroundOpacity(opacity: Int): Int = opacity.coerceIn(0, 100)

    internal fun backgroundAlpha(opacity: Int): Int =
        (normalizeBackgroundOpacity(opacity) * 255 + 50) / 100
}
