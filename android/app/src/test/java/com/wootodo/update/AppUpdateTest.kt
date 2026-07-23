package com.wootodo.update

import java.io.IOException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import okio.Timeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class AppUpdateTest {
    @Test
    fun `版本比较按数字而非字符串`() {
        val older = requireNotNull(AppVersion.parse("v0.9.9"))
        val newer = requireNotNull(AppVersion.parse("0.10.0"))

        assertTrue(newer > older)
        assertEquals(0, newer.compareTo(requireNotNull(AppVersion.parse("v0.10.0"))))
        assertTrue(
            AppUpdateResolver.resolve(
                currentVersionName = "0.10.0",
                release = release("v0.10.1"),
            ) is AppUpdateCheckResult.Available,
        )
        assertTrue(
            AppUpdateResolver.resolve(
                currentVersionName = "0.10.1",
                release = release("v0.10.0"),
            ) is AppUpdateCheckResult.Current,
        )
    }

    @Test
    fun `拒绝非三段式或溢出版本号`() {
        listOf("latest", "v1.2", "1.2.3-beta", "1.2.3.4", "01.2.3", "1.2.999999999999999999999").forEach {
            assertEquals(null, AppVersion.parse(it))
        }
    }

    @Test
    fun `解析正式Release并优先选择Android APK`() {
        val parsed = GitHubReleaseParser.parse(
            """
            {
              "tag_name":"v0.2.0",
              "draft":false,
              "prerelease":false,
              "html_url":"https://github.com/stophemo/woo-todo/releases/tag/v0.2.0",
              "assets":[
                {"name":"Woo-Todo-v0.2.0-macos-arm64.zip","browser_download_url":"https://github.com/stophemo/woo-todo/releases/download/v0.2.0/Woo-Todo-v0.2.0-macos-arm64.zip"},
                {"name":"Woo-Todo-v0.2.0-android.apk","browser_download_url":"https://github.com/stophemo/woo-todo/releases/download/v0.2.0/Woo-Todo-v0.2.0-android.apk"}
              ]
            }
            """.trimIndent(),
        )

        assertEquals("0.2.0", parsed.version.toString())
        assertEquals(
            "https://github.com/stophemo/woo-todo/releases/download/v0.2.0/Woo-Todo-v0.2.0-android.apk",
            parsed.downloadUrl,
        )
    }

    @Test
    fun `没有APK时回退发布页并拒绝草稿预发布或外部链接`() {
        val noApk = GitHubReleaseParser.parse(
            """
            {"tag_name":"v0.2.0","draft":false,"prerelease":false,
             "html_url":"https://github.com/stophemo/woo-todo/releases/tag/v0.2.0",
             "assets":[]}
            """.trimIndent(),
        )
        assertEquals(noApk.pageUrl, noApk.downloadUrl)

        val base = """
            {"tag_name":"v0.2.0","draft":%s,"prerelease":%s,
             "html_url":"%s","assets":[]}
        """.trimIndent()
        assertThrows(IllegalArgumentException::class.java) {
            GitHubReleaseParser.parse(base.format("true", "false", noApk.pageUrl))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitHubReleaseParser.parse(base.format("false", "true", noApk.pageUrl))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitHubReleaseParser.parse(base.format("false", "false", "https://example.com/release"))
        }
    }

    @Test
    fun `即使标记为正式发布也拒绝非稳定tag`() {
        listOf("0.2.0", "V0.2.0", "v0.2.0-beta", "v0.2").forEach { tag ->
            assertThrows(IllegalArgumentException::class.java) {
                GitHubReleaseParser.parse(
                    """
                    {"tag_name":"$tag","draft":false,"prerelease":false,
                     "html_url":"https://github.com/stophemo/woo-todo/releases/tag/$tag",
                     "assets":[]}
                    """.trimIndent(),
                )
            }
        }
    }

    @Test
    fun `发布页和APK路径必须与tag完全对应`() {
        assertThrows(IllegalArgumentException::class.java) {
            GitHubReleaseParser.parse(
                """
                {"tag_name":"v0.2.0","draft":false,"prerelease":false,
                 "html_url":"https://github.com/stophemo/woo-todo/releases/tag/v0.1.9",
                 "assets":[]}
                """.trimIndent(),
            )
        }
        val parsed = GitHubReleaseParser.parse(
            """
            {"tag_name":"v0.2.0","draft":false,"prerelease":false,
             "html_url":"https://github.com/stophemo/woo-todo/releases/tag/v0.2.0",
             "assets":[{"name":"Woo-Todo-v0.2.0-android.apk",
             "browser_download_url":"https://github.com/stophemo/woo-todo/releases/download/v0.1.9/Woo-Todo-v0.2.0-android.apk"}]}
            """.trimIndent(),
        )
        assertEquals(null, parsed.apkUrl)
        assertEquals(parsed.pageUrl, parsed.downloadUrl)

        val alternateName = GitHubReleaseParser.parse(
            """
            {"tag_name":"v0.2.0","draft":false,"prerelease":false,
             "html_url":"https://github.com/stophemo/woo-todo/releases/tag/v0.2.0",
             "assets":[{"name":"alternate.apk",
             "browser_download_url":"https://github.com/stophemo/woo-todo/releases/download/v0.2.0/alternate.apk"}]}
            """.trimIndent(),
        )
        assertEquals(null, alternateName.apkUrl)
    }

    @Test
    fun `协程取消会取消底层GitHub请求`() = runBlocking {
        val pending = PendingCall()
        val client = GitHubReleaseClient(Call.Factory { pending })
        val job = launch { client.latest() }

        yield()
        job.cancelAndJoin()

        assertTrue(pending.cancelled)
    }

    @Test
    fun `自动检查每24小时一次且处理版本后只提示更高版本`() {
        val now = 200_000_000L
        assertTrue(AppUpdatePolicy.shouldAutomaticallyCheck(0L, 0L, now))
        assertFalse(
            AppUpdatePolicy.shouldAutomaticallyCheck(
                lastSuccessfulCheckAt = now - AppUpdatePolicy.AUTOMATIC_CHECK_INTERVAL_MILLIS + 1,
                lastAttemptAt = 0L,
                now = now,
            ),
        )
        assertTrue(
            AppUpdatePolicy.shouldAutomaticallyCheck(
                lastSuccessfulCheckAt = now - AppUpdatePolicy.AUTOMATIC_CHECK_INTERVAL_MILLIS,
                lastAttemptAt = now - AppUpdatePolicy.FAILED_CHECK_RETRY_INTERVAL_MILLIS,
                now = now,
            ),
        )
        assertFalse(
            AppUpdatePolicy.shouldAutomaticallyCheck(
                lastSuccessfulCheckAt = 0L,
                lastAttemptAt = now - AppUpdatePolicy.FAILED_CHECK_RETRY_INTERVAL_MILLIS + 1,
                now = now,
            ),
        )
        assertTrue(
            AppUpdatePolicy.shouldAutomaticallyCheck(
                lastSuccessfulCheckAt = now + 1,
                lastAttemptAt = now + 1,
                now = now,
            ),
        )
        assertTrue(
            AppUpdatePolicy.shouldAutomaticallyPrompt(null, "v0.2.0"),
        )
        assertFalse(
            AppUpdatePolicy.shouldAutomaticallyPrompt("v0.2.0", "v0.2.0"),
        )
        assertTrue(
            AppUpdatePolicy.shouldAutomaticallyPrompt("v0.1.9", "v0.2.0"),
        )
        assertFalse(
            AppUpdatePolicy.shouldAutomaticallyPrompt("v0.3.0", "v0.2.0"),
        )
    }

    private fun release(tag: String): GitHubRelease = GitHubRelease(
        version = requireNotNull(AppVersion.parse(tag)),
        pageUrl = "https://github.com/stophemo/woo-todo/releases/tag/$tag",
        apkUrl = null,
    )

    private class PendingCall : Call {
        var cancelled = false

        override fun request(): Request = Request.Builder()
            .url("https://api.github.com")
            .build()

        override fun execute(): Response = throw IOException("测试调用不应同步执行")

        override fun enqueue(responseCallback: Callback) = Unit

        override fun cancel() {
            cancelled = true
        }

        override fun isExecuted(): Boolean = false

        override fun isCanceled(): Boolean = cancelled

        override fun timeout(): Timeout = Timeout.NONE

        override fun clone(): Call = this
    }
}
