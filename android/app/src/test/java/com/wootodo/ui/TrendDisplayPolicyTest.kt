package com.wootodo.ui

import com.wootodo.domain.TrendBucket
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Test

class TrendDisplayPolicyTest {
    @Test
    fun `只保留有记录或仍在进行的周期`() {
        val buckets = listOf(
            ended(LocalDate.of(2026, 7, 1), completed = 0, pass = 0),
            ended(LocalDate.of(2026, 7, 2), completed = 2, pass = 1),
            inProgress(LocalDate.of(2026, 7, 3)),
        )

        assertEquals(
            listOf(LocalDate.of(2026, 7, 2), LocalDate.of(2026, 7, 3)),
            visibleTrendBuckets(buckets).map { it.startDate },
        )
        assertEquals(1, hiddenTrendBucketCount(buckets))
    }

    @Test
    fun `全部为空时不展示任何周期`() {
        val buckets = listOf(
            ended(LocalDate.of(2026, 7, 1), completed = 0, pass = 0),
            ended(LocalDate.of(2026, 7, 2), completed = 0, pass = 0),
        )

        assertEquals(emptyList<TrendBucket>(), visibleTrendBuckets(buckets))
        assertEquals(2, hiddenTrendBucketCount(buckets))
    }

    private fun ended(date: LocalDate, completed: Int, pass: Int) = TrendBucket(
        startDate = date,
        endDateExclusive = date.plusDays(1),
        completed = completed,
        pass = pass,
        isEnded = true,
    )

    private fun inProgress(date: LocalDate) = TrendBucket(
        startDate = date,
        endDateExclusive = date.plusDays(1),
        isEnded = false,
    )
}
