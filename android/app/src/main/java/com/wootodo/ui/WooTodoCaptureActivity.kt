package com.wootodo.ui

import android.content.Context
import com.journeyapps.barcodescanner.CaptureActivity
import com.journeyapps.barcodescanner.ScanOptions
import com.wootodo.R

/** 仅供应用内二维码入口使用，方向交给设备与用户的旋转设置决定。 */
class WooTodoCaptureActivity : CaptureActivity()

internal object WooTodoScanOptions {
    fun create(context: Context): ScanOptions = ScanOptions().apply {
        setDesiredBarcodeFormats(ScanOptions.QR_CODE)
        setCaptureActivity(WooTodoCaptureActivity::class.java)
        setPrompt(context.getString(R.string.scan_qr_prompt))
        setBeepEnabled(false)
        setBarcodeImageEnabled(false)
        setOrientationLocked(false)
    }
}
