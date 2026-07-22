package com.wootodo.ui

import android.content.Context
import android.widget.EditText
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EditableTextContractInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `可编辑文本保留长按操作入口`() {
        val input = EditText(context).apply {
            isLongClickable = false
            enableEditableTextActions()
        }

        assertTrue(input.isLongClickable)
    }

    @Test
    fun `只读文本允许选择和长按复制`() {
        val value = TextView(context).apply {
            enableReadOnlyTextSelection()
        }

        assertTrue(value.isTextSelectable)
        assertTrue(value.isLongClickable)
    }
}
