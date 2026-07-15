package com.wootodo.sync

import java.io.IOException
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncRuntimeTest {
    @Test
    fun `未配对时不执行同步`() = runBlocking {
        val runtime = SyncRuntime(runnerFactory = { null })

        assertEquals(SyncExecutionResult.NotConfigured, runtime.synchronize())
        assertEquals(SyncRuntimeState.Unpaired, runtime.state.value)
    }

    @Test
    fun `同步成功时发布上传下载摘要`() = runBlocking {
        val summary = SyncRunSummary(pushed = 2, pulled = 3, pages = 1, finalCursor = 8)
        val runtime = SyncRuntime(
            runnerFactory = { SyncRunner { summary } },
            clockMillis = { 123L },
        )

        assertEquals(SyncExecutionResult.Succeeded(summary), runtime.synchronize())
        assertEquals(SyncRuntimeState.Succeeded(summary, 123L), runtime.state.value)
    }

    @Test
    fun `同步工厂和执行器都在IO调度器运行`() = runBlocking {
        val dispatcher = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "sync-io-test")
        }.asCoroutineDispatcher()
        try {
            val executedThreads = mutableListOf<String>()
            val summary = SyncRunSummary(pushed = 0, pulled = 0, pages = 1, finalCursor = 0)
            val runtime = SyncRuntime(
                runnerFactory = {
                    executedThreads += Thread.currentThread().name
                    SyncRunner {
                        executedThreads += Thread.currentThread().name
                        summary
                    }
                },
                ioDispatcher = dispatcher,
            )

            assertEquals(SyncExecutionResult.Succeeded(summary), runtime.synchronize())
            assertEquals(2, executedThreads.size)
            assertTrue(executedThreads.all { it.startsWith("sync-io-test") })
        } finally {
            dispatcher.close()
        }
    }

    @Test
    fun `仅网络和可恢复服务错误进入退避重试`() {
        assertTrue(
            SyncFailurePolicy.describe(SyncApiException.Transport(IOException("offline"))).retryable,
        )
        assertTrue(
            SyncFailurePolicy.describe(serverError(503)).retryable,
        )
        assertFalse(
            SyncFailurePolicy.describe(serverError(401)).retryable,
        )
        assertFalse(
            SyncFailurePolicy.describe(SyncCoordinatorException.InvalidPushSummary).retryable,
        )
    }

    private fun serverError(status: Int): SyncApiException.Server = SyncApiException.Server(
        statusCode = status,
        payload = ServerErrorPayload("TEST_$status", "测试错误"),
        requestId = "request-test",
    )
}
