package com.wootodo.ui

import com.wootodo.domain.TrendBucket

/**
 * 统计页面只展示有内容的时间桶：已结束但没有任何样本的周期会把手机屏幕
 * 塞满一堆 0，因此折叠成一行计数。
 */
internal fun visibleTrendBuckets(buckets: List<TrendBucket>): List<TrendBucket> =
    buckets.filter { it.sampleCount > 0 || !it.isEnded }

internal fun hiddenTrendBucketCount(buckets: List<TrendBucket>): Int =
    buckets.size - visibleTrendBuckets(buckets).size
