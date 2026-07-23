package com.wootodo.update

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.time.Duration
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject

/** 可比较的三段式版本号，接受 GitHub 常见的 v0.1.4 形式。 */
internal class AppVersion private constructor(
    val major: Long,
    val minor: Long,
    val patch: Long,
) : Comparable<AppVersion> {
    override fun compareTo(other: AppVersion): Int =
        compareValuesBy(this, other, AppVersion::major, AppVersion::minor, AppVersion::patch)

    override fun toString(): String = "$major.$minor.$patch"

    companion object {
        private val PATTERN = Regex("^[vV]?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")

        fun parse(source: String): AppVersion? {
            val match = PATTERN.matchEntire(source.trim()) ?: return null
            val values = match.groupValues.drop(1).map { it.toLongOrNull() ?: return null }
            return AppVersion(values[0], values[1], values[2])
        }
    }
}

internal data class GitHubRelease(
    val version: AppVersion,
    val pageUrl: String,
    val apkUrl: String?,
) {
    val versionLabel: String get() = "v$version"
    val downloadUrl: String get() = apkUrl ?: pageUrl
}

internal object GitHubReleaseParser {
    private const val REPOSITORY = "stophemo/woo-todo"
    private const val RELEASE_PAGE_PREFIX = "/$REPOSITORY/releases/tag/"
    private const val RELEASE_DOWNLOAD_PREFIX = "/$REPOSITORY/releases/download/"

    fun parse(source: String): GitHubRelease {
        val value = JSONObject(source)
        require(value.opt("draft") is Boolean && !value.getBoolean("draft"))
        require(value.opt("prerelease") is Boolean && !value.getBoolean("prerelease"))
        val tag = requiredString(value, "tag_name")
        val version = AppVersion.parse(tag)
            ?: throw IllegalArgumentException("GitHub release tag 不是受支持的版本号")
        require(tag == "v$version") { "GitHub release tag 必须是稳定版本" }
        val pageUrl = requiredString(value, "html_url").also {
            require(isRepositoryUrl(it, "$RELEASE_PAGE_PREFIX$tag", exactPath = true))
        }
        val expectedApkName = "Woo-Todo-$tag-android.apk"
        val expectedApkPath = "$RELEASE_DOWNLOAD_PREFIX$tag/$expectedApkName"
        val assets = value.optJSONArray("assets") ?: JSONArray()
        var apkUrl: String? = null
        for (index in 0 until assets.length()) {
            val asset = assets.optJSONObject(index) ?: continue
            val name = asset.optString("name")
            val url = asset.optString("browser_download_url")
            if (name == expectedApkName &&
                isRepositoryUrl(url, expectedApkPath, exactPath = true)
            ) {
                apkUrl = url
                break
            }
        }
        return GitHubRelease(version, pageUrl, apkUrl)
    }

    private fun requiredString(value: JSONObject, name: String): String =
        (value.opt(name) as? String)?.takeIf(String::isNotBlank)
            ?: throw IllegalArgumentException("GitHub release 缺少 $name")

    private fun isRepositoryUrl(
        value: String,
        expectedPath: String,
        exactPath: Boolean = false,
    ): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals("github.com", ignoreCase = true) &&
            uri.port == -1 &&
            uri.rawUserInfo == null &&
            uri.rawQuery == null &&
            uri.rawFragment == null &&
            if (exactPath) uri.rawPath == expectedPath else uri.rawPath?.startsWith(expectedPath) == true
    }.getOrDefault(false)
}

internal fun interface LatestReleaseSource {
    suspend fun latest(): GitHubRelease
}

internal class GitHubReleaseClient(
    private val callFactory: Call.Factory = OkHttpClient.Builder()
        .connectTimeout(Duration.ofSeconds(5))
        .readTimeout(Duration.ofSeconds(10))
        .callTimeout(Duration.ofSeconds(15))
        .build(),
) : LatestReleaseSource {
    override suspend fun latest(): GitHubRelease = suspendCancellableCoroutine { continuation ->
        val request = Request.Builder()
            .url(API_URL)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header("User-Agent", "Woo-Todo-Android")
            .get()
            .build()
        val call = callFactory.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                continuation.resumeWithException(error)
            }

            override fun onResponse(call: Call, response: Response) {
                if (!continuation.isActive) {
                    response.close()
                    return
                }
                val result = runCatching {
                    response.use {
                        if (!it.isSuccessful) throw IOException("GitHub 返回 HTTP ${it.code}")
                        val body = it.body ?: throw IOException("GitHub 响应为空")
                        val bytes = body.byteStream().use { stream ->
                            stream.readLimited(MAX_RESPONSE_BYTES)
                        }
                        GitHubReleaseParser.parse(String(bytes, StandardCharsets.UTF_8))
                    }
                }
                result.fold(
                    onSuccess = { release ->
                        continuation.resume(release)
                    },
                    onFailure = { error ->
                        continuation.resumeWithException(error)
                    },
                )
            }
        })
    }

    private companion object {
        const val API_URL = "https://api.github.com/repos/stophemo/woo-todo/releases/latest"
        const val MAX_RESPONSE_BYTES = 512 * 1024
    }
}

private fun java.io.InputStream.readLimited(maxBytes: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    var total = 0
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        if (total > maxBytes) throw IOException("GitHub 响应过大")
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

internal sealed interface AppUpdateCheckResult {
    data class Available(val release: GitHubRelease) : AppUpdateCheckResult
    data object Current : AppUpdateCheckResult
}

internal object AppUpdateResolver {
    fun resolve(currentVersionName: String, release: GitHubRelease): AppUpdateCheckResult {
        val current = AppVersion.parse(currentVersionName)
            ?: throw IllegalArgumentException("当前应用版本号无效")
        return if (release.version > current) {
            AppUpdateCheckResult.Available(release)
        } else {
            AppUpdateCheckResult.Current
        }
    }
}

internal object AppUpdatePolicy {
    const val AUTOMATIC_CHECK_INTERVAL_MILLIS = 24L * 60L * 60L * 1_000L
    const val FAILED_CHECK_RETRY_INTERVAL_MILLIS = 15L * 60L * 1_000L

    fun shouldAutomaticallyCheck(
        lastSuccessfulCheckAt: Long,
        lastAttemptAt: Long,
        now: Long,
    ): Boolean = elapsed(lastSuccessfulCheckAt, now) >= AUTOMATIC_CHECK_INTERVAL_MILLIS &&
        elapsed(lastAttemptAt, now) >= FAILED_CHECK_RETRY_INTERVAL_MILLIS

    fun shouldAutomaticallyPrompt(
        lastHandledVersion: String?,
        candidateVersion: String,
    ): Boolean {
        val candidate = AppVersion.parse(candidateVersion)
        val handled = lastHandledVersion?.let(AppVersion::parse)
        return when {
            candidate == null || handled == null -> lastHandledVersion != candidateVersion
            else -> candidate > handled
        }
    }

    private fun elapsed(previous: Long, now: Long): Long = when {
        previous <= 0L || now < previous -> Long.MAX_VALUE
        else -> now - previous
    }
}

internal class AppUpdatePreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        FILE_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    fun shouldAutomaticallyCheck(now: Long): Boolean {
        return AppUpdatePolicy.shouldAutomaticallyCheck(
            lastSuccessfulCheckAt = preferences.getLong(KEY_LAST_CHECK_AT, 0L),
            lastAttemptAt = preferences.getLong(KEY_LAST_ATTEMPT_AT, 0L),
            now = now,
        )
    }

    @Synchronized
    fun markAttempted(now: Long) {
        preferences.edit().putLong(KEY_LAST_ATTEMPT_AT, now).apply()
    }

    @Synchronized
    fun markCheckCompleted(now: Long) {
        preferences.edit().putLong(KEY_LAST_CHECK_AT, now).apply()
    }

    @Synchronized
    fun shouldPromptAutomatically(version: String): Boolean =
        AppUpdatePolicy.shouldAutomaticallyPrompt(
            lastHandledVersion = preferences.getString(KEY_LAST_HANDLED_VERSION, null)
                ?: preferences.getString(LEGACY_KEY_LAST_PROMPTED_VERSION, null),
            candidateVersion = version,
        )

    @Synchronized
    fun markHandled(version: String) {
        preferences.edit()
            .putString(KEY_LAST_HANDLED_VERSION, version)
            .remove(LEGACY_KEY_LAST_PROMPTED_VERSION)
            .apply()
    }

    private companion object {
        const val FILE_NAME = "app_update_state"
        const val KEY_LAST_CHECK_AT = "last_automatic_check_at"
        const val KEY_LAST_ATTEMPT_AT = "last_automatic_attempt_at"
        const val KEY_LAST_HANDLED_VERSION = "last_handled_version"
        const val LEGACY_KEY_LAST_PROMPTED_VERSION = "last_prompted_version"
    }
}
