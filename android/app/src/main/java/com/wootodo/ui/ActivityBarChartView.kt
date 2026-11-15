package com.wootodo.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import com.wootodo.R
import com.wootodo.domain.DayActivity
import java.time.format.DateTimeFormatter
import java.util.Locale

class ActivityBarChartView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {
    private var activity: List<DayActivity> = emptyList()
    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val zeroPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 11f * resources.displayMetrics.scaledDensity
        color = ContextCompat.getColor(context, R.color.muted)
    }
    private val emptyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 14f * resources.displayMetrics.scaledDensity
        color = ContextCompat.getColor(context, R.color.muted)
        textAlign = Paint.Align.CENTER
    }
    private val formatter = DateTimeFormatter.ofPattern("M/d", Locale.SIMPLIFIED_CHINESE)

    fun setData(values: List<DayActivity>) {
        activity = values
        val total = values.sumOf { it.completed }
        contentDescription = context.getString(R.string.stats_chart_description, total)
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredHeight = (180 * resources.displayMetrics.density).toInt()
        setMeasuredDimension(
            resolveSize(suggestedMinimumWidth, widthMeasureSpec),
            resolveSize(desiredHeight, heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val horizontalPadding = 8f * resources.displayMetrics.density
        val labelHeight = 22f * resources.displayMetrics.density
        val chartTop = 12f * resources.displayMetrics.density
        val chartBottom = height - labelHeight
        val chartHeight = (chartBottom - chartTop).coerceAtLeast(1f)
        val maxValue = (activity.maxOfOrNull { it.completed } ?: 0).coerceAtLeast(1)
        val availableWidth = width - horizontalPadding * 2
        val slot = availableWidth / 14f
        val barWidth = slot * 0.62f
        barPaint.color = ContextCompat.getColor(context, R.color.primary)
        zeroPaint.color = ContextCompat.getColor(context, R.color.line)

        if (activity.isEmpty() || activity.all { it.completed == 0 }) {
            canvas.drawText(
                context.getString(R.string.stats_no_activity),
                width / 2f,
                chartTop + chartHeight / 2f,
                emptyPaint,
            )
            return
        }

        activity.forEachIndexed { index, day ->
            val barHeight = chartHeight * day.completed / maxValue
            val left = horizontalPadding + slot * index + (slot - barWidth) / 2f
            val right = left + barWidth
            val top = chartBottom - barHeight
            val rect = RectF(left, top, right, chartBottom)
            val radius = barWidth / 2f
            canvas.drawRoundRect(
                rect,
                radius,
                radius,
                if (day.completed == 0) zeroPaint else barPaint,
            )
        }

        val labelIndices = listOf(0, activity.lastIndex / 2, activity.lastIndex)
        labelIndices.distinct().forEach { index ->
            val label = activity[index].date.format(formatter)
            val x = horizontalPadding + slot * index + slot / 2f
            labelPaint.textAlign = when (index) {
                0 -> Paint.Align.LEFT
                activity.lastIndex -> Paint.Align.RIGHT
                else -> Paint.Align.CENTER
            }
            val adjustedX = when (index) {
                0 -> horizontalPadding
                activity.lastIndex -> width - horizontalPadding
                else -> x
            }
            canvas.drawText(label, adjustedX, height - 4f * resources.displayMetrics.density, labelPaint)
        }
    }
}
