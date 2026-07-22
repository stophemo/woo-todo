package com.wootodo.sync

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.FeatureInfo
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.ScanOptions
import com.wootodo.ui.WooTodoCaptureActivity
import com.wootodo.ui.WooTodoScanOptions
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QrScannerContractInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `相机权限仅声明且无相机设备仍可安装`() {
        val packageInfo = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS or PackageManager.GET_CONFIGURATIONS,
        )

        assertTrue(packageInfo.requestedPermissions.orEmpty().contains(Manifest.permission.CAMERA))
        val camera = packageInfo.reqFeatures.orEmpty().firstOrNull {
            it.name == PackageManager.FEATURE_CAMERA_ANY
        }
        assertNotNull(camera)
        assertTrue(requireNotNull(camera).flags and FeatureInfo.FLAG_REQUIRED == 0)
    }

    @Test
    fun `扫码Activity不对其他应用暴露且不强制横屏`() {
        val activityInfo = context.packageManager.getActivityInfo(
            ComponentName(context, WooTodoCaptureActivity::class.java),
            0,
        )

        assertFalse(activityInfo.exported)
        assertTrue(activityInfo.screenOrientation == ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED)
    }

    @Test
    fun `扫码Intent只接受二维码且使用应用内Activity`() {
        val intent = WooTodoScanOptions.create(context).createScanIntent(context)

        assertTrue(intent.getStringExtra(Intents.Scan.FORMATS) == ScanOptions.QR_CODE)
        assertFalse(intent.getBooleanExtra(Intents.Scan.ORIENTATION_LOCKED, true))
        assertTrue(intent.component?.className == WooTodoCaptureActivity::class.java.name)
    }
}
