package com.wootodo.ui

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.view.ContextThemeWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceListContractInstrumentedTest {
    private val context: Context
        get() = ContextThemeWrapper(
            ApplicationProvider.getApplicationContext(),
            R.style.Theme_WooTodo,
        )

    @Test
    fun `设备行只读且不包含移除入口`() {
        val row = LayoutInflater.from(context).inflate(
            R.layout.item_cross_device_device,
            FrameLayout(context),
            false,
        )

        assertNotNull(row.findViewById<View>(R.id.device_name))
        assertNotNull(row.findViewById<View>(R.id.device_meta))
        assertNotNull(row.findViewById<View>(R.id.device_last_seen))
        assertFalse(row.allViews().any { it is Button || it is ImageButton })
    }

    @Test
    fun `跨设备页设备列表保持只读说明`() {
        val page = LayoutInflater.from(context).inflate(
            R.layout.activity_cross_device_settings,
            FrameLayout(context),
            false,
        )

        assertNotNull(page.findViewById<View>(R.id.device_list))
        val expectedNote = context.getString(R.string.cross_device_devices_note)
        val notes = page.allViews()
            .filterIsInstance<TextView>()
            .filter { it.text.toString() == expectedNote }
        assertEquals(1, notes.count())
        assertFalse(page.findViewById<View>(R.id.device_list).allViews().any {
            it is Button || it is ImageButton
        })
    }

    private fun View.allViews(): Sequence<View> = sequence {
        yield(this@allViews)
        if (this@allViews is ViewGroup) {
            for (index in 0 until childCount) {
                yieldAll(getChildAt(index).allViews())
            }
        }
    }
}
