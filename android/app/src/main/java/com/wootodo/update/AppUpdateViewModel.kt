package com.wootodo.update

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.wootodo.BuildConfig
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

internal data class AppUpdateEvent(
    val result: Result<AppUpdateCheckResult>,
    val reportToUser: Boolean,
    val completedAt: Long,
)

/** 配置变更时保留正在进行的请求，并把唯一结果交给新的 Activity 消费。 */
internal class AppUpdateViewModel(
    private val releaseSource: LatestReleaseSource = GitHubReleaseClient(),
    private val currentVersionName: String = BuildConfig.VERSION_NAME,
) : ViewModel() {
    private val eventChannel = Channel<AppUpdateEvent>(Channel.BUFFERED)
    val events = eventChannel.receiveAsFlow()

    private var requestJob: Job? = null
    private var reportToUser = false

    fun check(manual: Boolean) {
        if (manual) reportToUser = true
        if (requestJob?.isActive == true) return
        requestJob = viewModelScope.launch {
            try {
                val result = runCatching {
                    AppUpdateResolver.resolve(currentVersionName, releaseSource.latest())
                }
                val shouldReport = reportToUser
                reportToUser = false
                eventChannel.send(
                    AppUpdateEvent(
                        result = result,
                        reportToUser = shouldReport,
                        completedAt = System.currentTimeMillis(),
                    ),
                )
            } finally {
                requestJob = null
            }
        }
    }
}
