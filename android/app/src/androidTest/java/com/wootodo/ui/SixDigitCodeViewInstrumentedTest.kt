package com.wootodo.ui

import android.content.Context
import android.content.res.Configuration
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.wootodo.R
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SixDigitCodeViewInstrumentedTest {
    @Test
    fun darkModeDigitsContrastWithCellBackground() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val configuration = Configuration(base.resources.configuration).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                Configuration.UI_MODE_NIGHT_YES
        }
        val nightContext = base.createConfigurationContext(configuration)
        var textColor = 0
        var background = 0

        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val view = SixDigitCodeView(nightContext)
            view.setCode("123456")
            view.setEditable(false)
            textColor = view.findViewById<TextView>(R.id.pin_digit_0).currentTextColor
            background = ContextCompat.getColor(view.context, R.color.app_background)
        }

        assertNotEquals(
            "深色模式下六位码数字不能与格子背景同色",
            background,
            textColor,
        )
    }
}
