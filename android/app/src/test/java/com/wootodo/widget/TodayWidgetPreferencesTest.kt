package com.wootodo.widget

import org.junit.Assert.assertEquals
import org.junit.Test

class TodayWidgetPreferencesTest {
    @Test
    fun `不透明度会收敛到有效范围并换算为颜色通道`() {
        assertEquals(70, TodayWidgetPreferences.DEFAULT_BACKGROUND_OPACITY)
        assertEquals(0, TodayWidgetPreferences.normalizeBackgroundOpacity(-1))
        assertEquals(42, TodayWidgetPreferences.normalizeBackgroundOpacity(42))
        assertEquals(100, TodayWidgetPreferences.normalizeBackgroundOpacity(101))
        assertEquals(0, TodayWidgetPreferences.backgroundAlpha(0))
        assertEquals(128, TodayWidgetPreferences.backgroundAlpha(50))
        assertEquals(179, TodayWidgetPreferences.backgroundAlpha(70))
        assertEquals(255, TodayWidgetPreferences.backgroundAlpha(100))
    }
}
