package com.wootodo.sync

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncJobSchedulerContractInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `同步任务网络约束对应声明网络状态权限`() {
        val requested = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        ).requestedPermissions.orEmpty()

        assertTrue(requested.contains(Manifest.permission.ACCESS_NETWORK_STATE))
        assertTrue(requested.contains(Manifest.permission.INTERNET))
        assertFalse(requested.contains(Manifest.permission.CHANGE_WIFI_MULTICAST_STATE))
        // 邀请二维码扫描需要相机；只在用户点「扫描邀请二维码」时申请。
        assertTrue(requested.contains(Manifest.permission.CAMERA))
    }
}
