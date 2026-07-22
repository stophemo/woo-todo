package com.wootodo.ui

import android.widget.EditText
import android.widget.TextView

internal fun EditText.enableEditableTextActions() {
    isLongClickable = true
}

internal fun TextView.enableReadOnlyTextSelection() {
    isLongClickable = true
    setTextIsSelectable(true)
}
