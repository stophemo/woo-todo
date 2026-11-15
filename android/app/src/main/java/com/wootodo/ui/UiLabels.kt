package com.wootodo.ui

import androidx.annotation.StringRes
import com.wootodo.R
import com.wootodo.domain.TaskStatus

@StringRes
fun TaskStatus.labelRes(): Int =
    when (this) {
        TaskStatus.PENDING -> R.string.status_pending
        TaskStatus.COMPLETED -> R.string.status_completed
        TaskStatus.PASS -> R.string.status_passed
    }
