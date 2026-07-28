package com.wootodo.update

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.wootodo.BuildConfig
import java.io.File
import java.io.IOException
import java.time.Duration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.coroutines.coroutineContext

internal data class ApkIdentity(
    val packageName: String,
    val versionName: String?,
    val versionCode: Long,
    val signerCertificates: Set<List<Byte>>,
)

internal object ApkUpdateIdentityPolicy {
    fun validate(
        installed: ApkIdentity,
        downloaded: ApkIdentity,
        expectedVersion: AppVersion,
    ) {
        require(downloaded.packageName == installed.packageName) { "更新包的应用标识不一致" }
        require(downloaded.versionName == expectedVersion.toString()) { "更新包的版本号不一致" }
        require(downloaded.versionCode > installed.versionCode) { "更新包不是更高版本" }
        require(downloaded.signerCertificates.isNotEmpty()) { "无法读取更新包签名" }
        require(downloaded.signerCertificates == installed.signerCertificates) {
            "更新包签名与当前应用不一致"
        }
    }
}

internal class ApkUpdateInstaller(
    context: Context,
    private val callFactory: Call.Factory = OkHttpClient.Builder()
        .connectTimeout(Duration.ofSeconds(10))
        .readTimeout(Duration.ofMinutes(2))
        .callTimeout(Duration.ofMinutes(3))
        .build(),
) {
    private val applicationContext = context.applicationContext
    private val packageManager = applicationContext.packageManager
    private val updateDirectory = File(applicationContext.cacheDir, "app-updates")

    fun canRequestPackageInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    fun unknownSourcesSettingsIntent(): Intent = Intent(
        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${applicationContext.packageName}"),
    )

    suspend fun downloadAndVerify(release: GitHubRelease): File = withContext(Dispatchers.IO) {
        val apkUrl = release.apkUrl ?: throw IOException("该版本没有 Android APK")
        check(GitHubReleaseParser.isValid(release)) { "更新下载地址无效" }
        updateDirectory.mkdirs()
        check(updateDirectory.isDirectory) { "无法创建更新缓存目录" }

        val destination = File(updateDirectory, "Woo-Todo-${release.versionLabel}-android.apk")
        val partial = File(updateDirectory, "${destination.name}.part")
        updateDirectory.listFiles()?.forEach { file ->
            if (file != destination && file != partial) file.delete()
        }
        partial.delete()

        val request = Request.Builder()
            .url(apkUrl)
            .header("Accept", "application/vnd.android.package-archive")
            .header("User-Agent", "Woo-Todo-Android")
            .get()
            .build()
        val call = callFactory.newCall(request)
        try {
            call.execute().use { response ->
                if (!response.isSuccessful) throw IOException("下载更新失败（HTTP ${response.code}）")
                val body = response.body ?: throw IOException("更新下载响应为空")
                val contentLength = body.contentLength()
                if (contentLength !in 1..MAX_APK_BYTES) throw IOException("更新包大小无效")
                body.byteStream().use { input ->
                    partial.outputStream().buffered().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        var total = 0L
                        while (true) {
                            coroutineContext.ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > MAX_APK_BYTES) throw IOException("更新包过大")
                            output.write(buffer, 0, count)
                        }
                        if (total != contentLength) throw IOException("更新包下载不完整")
                    }
                }
            }
            verifyArchive(partial, release.version)
            destination.delete()
            if (!partial.renameTo(destination)) throw IOException("无法保存更新包")
            destination
        } catch (error: Throwable) {
            partial.delete()
            throw error
        }
    }

    fun installIntent(apk: File): Intent {
        require(apk.parentFile?.canonicalFile == updateDirectory.canonicalFile) {
            "更新包不在应用缓存目录"
        }
        val uri = FileProvider.getUriForFile(
            applicationContext,
            "${BuildConfig.APPLICATION_ID}.update-files",
            apk,
        )
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    private fun verifyArchive(apk: File, expectedVersion: AppVersion) {
        val flags = PackageManager.PackageInfoFlags.of(
            PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
        )
        val installed = packageManager.getPackageInfo(applicationContext.packageName, flags)
        val downloaded = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IOException("无法解析更新包")
        try {
            ApkUpdateIdentityPolicy.validate(
                installed = installed.toIdentity(),
                downloaded = downloaded.toIdentity(),
                expectedVersion = expectedVersion,
            )
        } catch (error: IllegalArgumentException) {
            throw IOException(error.message ?: "更新包身份校验失败", error)
        }
    }

    private fun PackageInfo.toIdentity(): ApkIdentity {
        val signers = signingInfo?.apkContentsSigners
            ?.map { signature -> signature.toByteArray().toList() }
            ?.toSet()
            .orEmpty()
        return ApkIdentity(
            packageName = packageName,
            versionName = versionName,
            versionCode = longVersionCode,
            signerCertificates = signers,
        )
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val MAX_APK_BYTES = 100L * 1024L * 1024L
    }
}
