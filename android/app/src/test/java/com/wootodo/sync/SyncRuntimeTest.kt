package com.wootodo.sync

import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncRuntimeTest {
    @Test
    fun `读取安全存储期间不误报未配对`() {
        val runtime = SyncRuntime(runnerFactory = { null })

        assertEquals(SyncRuntimeState.Loading, runtime.state.value)

        runtime.refreshConfiguration(configured = true)
        assertEquals(SyncRuntimeState.Idle, runtime.state.value)
    }

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
    fun `同步方式重绑等待当前同步结束且下一轮使用新配置`() = runBlocking {
        val dispatcher = Executors.newFixedThreadPool(2).asCoroutineDispatcher()
        val firstRunStarted = CompletableDeferred<Unit>()
        val releaseFirstRun = CountDownLatch(1)
        val observedBindings = Collections.synchronizedList(mutableListOf<String>())
        var binding = "旧空间"
        val summary = SyncRunSummary(pushed = 0, pulled = 0, pages = 1, finalCursor = 0)
        val runtime = SyncRuntime(
            runnerFactory = {
                val capturedBinding = binding
                SyncRunner {
                    observedBindings += capturedBinding
                    if (capturedBinding == "旧空间") {
                        firstRunStarted.complete(Unit)
                        check(releaseFirstRun.await(5, TimeUnit.SECONDS)) { "测试同步等待超时" }
                    }
                    summary
                }
            },
            ioDispatcher = dispatcher,
        )

        try {
            val firstSync = async(start = CoroutineStart.UNDISPATCHED) { runtime.synchronize() }
            withTimeout(5_000) { firstRunStarted.await() }
            val rebind = async(start = CoroutineStart.UNDISPATCHED) {
                runtime.withExclusiveConfiguration { binding = "新空间" }
            }

            assertFalse(rebind.isCompleted)
            assertEquals("旧空间", binding)

            releaseFirstRun.countDown()
            assertEquals(SyncExecutionResult.Succeeded(summary), firstSync.await())
            rebind.await()
            assertEquals(SyncExecutionResult.Succeeded(summary), runtime.synchronize())
            assertEquals(listOf("旧空间", "新空间"), observedBindings)
        } finally {
            releaseFirstRun.countDown()
            dispatcher.close()
        }
    }

    @Test
    fun `仅网络和可恢复服务错误进入退避重试`() {
        val transportFailure =
            SyncFailurePolicy.describe(SyncApiException.Transport(IOException("offline")))
        assertTrue(transportFailure.retryable)
        assertEquals("同步服务暂时不可达，网络恢复后会自动重试", transportFailure.message)
        val localTransportFailure = SyncFailurePolicy.describe(
            SyncApiException.Transport(IOException("offline"), localNetwork = true),
        )
        assertTrue(localTransportFailure.retryable)
        assertEquals(
            "局域网同步地址暂时不可达；若 Mac 的 IP 已变化，请重新扫描 Mac 当前的同步二维码",
            localTransportFailure.message,
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

    @Test
    fun `同步空间达到容量上限时保留本地任务且不自动重试`() = runBlocking {
        val error = SyncApiException.Server(
            statusCode = 507,
            payload = ServerErrorPayload("VAULT_CAPACITY_REACHED", "同步空间已满"),
            requestId = "request-capacity",
        )
        val runtime = SyncRuntime(
            runnerFactory = { SyncRunner { throw error } },
            clockMillis = { 456L },
        )

        assertEquals(SyncExecutionResult.Failed(retryable = false), runtime.synchronize())
        assertEquals(
            SyncRuntimeState.Failed(
                message = "同步空间已达到存储上限，本地待发送任务仍会保留；请切换同步空间或稍后重试",
                retryable = false,
                finishedAt = 456L,
            ),
            runtime.state.value,
        )
    }

    private fun serverError(status: Int): SyncApiException.Server = SyncApiException.Server(
        statusCode = status,
        payload = ServerErrorPayload("TEST_$status", "测试错误"),
        requestId = "request-test",
    )
}
