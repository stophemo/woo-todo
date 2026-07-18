package com.wootodo.ui

import android.view.View
import androidx.activity.ComponentActivity
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

internal fun ComponentActivity.applySystemBarInsets(root: View) {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    val initialPadding = Insets.of(
        root.paddingLeft,
        root.paddingTop,
        root.paddingRight,
        root.paddingBottom,
    )
    ViewCompat.setOnApplyWindowInsetsListener(root) { view, windowInsets ->
        val systemBars = windowInsets.getInsets(
            WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
        )
        val ime = windowInsets.getInsets(WindowInsetsCompat.Type.ime())
        view.setPadding(
            initialPadding.left + maxOf(systemBars.left, ime.left),
            initialPadding.top + maxOf(systemBars.top, ime.top),
            initialPadding.right + maxOf(systemBars.right, ime.right),
            initialPadding.bottom + maxOf(systemBars.bottom, ime.bottom),
        )
        windowInsets
    }
    ViewCompat.requestApplyInsets(root)
}
