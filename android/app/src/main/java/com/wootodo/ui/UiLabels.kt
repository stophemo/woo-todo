package com.wootodo.ui

import androidx.annotation.StringRes
import com.wootodo.R
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType

@StringRes
fun QuestLine.labelRes(): Int =
    when (this) {
        QuestLine.MAIN -> R.string.main_quest
        QuestLine.SIDE -> R.string.side_quest
        QuestLine.EXTRA -> R.string.extra_quest
    }

@StringRes
fun TaskTimeType.labelRes(): Int =
    when (this) {
        TaskTimeType.DAY -> R.string.scope_today
        TaskTimeType.WEEK -> R.string.scope_week
        TaskTimeType.MONTH -> R.string.scope_month
        TaskTimeType.LEISURE -> R.string.scope_leisure
    }

@StringRes
fun Recurrence.labelRes(): Int =
    when (this) {
        Recurrence.ONCE -> R.string.one_time
        Recurrence.DAILY -> R.string.repeat_daily
        Recurrence.WEEKLY -> R.string.repeat_weekly
        Recurrence.MONTHLY -> R.string.repeat_monthly
    }

@StringRes
fun TaskStatus.labelRes(): Int =
    when (this) {
        TaskStatus.PENDING -> R.string.status_pending
        TaskStatus.COMPLETED -> R.string.status_completed
        TaskStatus.PASS -> R.string.status_passed
    }
