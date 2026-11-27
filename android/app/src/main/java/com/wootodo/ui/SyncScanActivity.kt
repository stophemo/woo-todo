package com.wootodo.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.wootodo.R

/**
 * 小窗口扫码：只申请相机权限，识别到二维码后立即返回文本。
 * 不使用 ZXing 自带的 CaptureActivity，避免全屏横屏扫描界面。
 */
class SyncScanActivity : AppCompatActivity() {
    private lateinit var barcodeView: DecoratedBarcodeView
    private var previewStarted = false
    private var handled = false

    private val requestCamera = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            startPreview()
        } else {
            Toast.makeText(this, R.string.scan_camera_required, Toast.LENGTH_SHORT).show()
            setResult(RESULT_CANCELED)
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sync_scan)
        barcodeView = findViewById(R.id.scan_barcode_view)
        barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        barcodeView.setStatusText("")
        barcodeView.statusView.visibility = android.view.View.GONE
        barcodeView.decodeSingle(object : BarcodeCallback {
            override fun barcodeResult(result: BarcodeResult) {
                if (handled) return
                handled = true
                setResult(
                    RESULT_OK,
                    Intent().putExtra(EXTRA_RESULT, result.text),
                )
                finish()
            }
        })
        findViewById<android.view.View>(R.id.scan_close).setOnClickListener {
            setResult(RESULT_CANCELED)
            finish()
        }
        if (hasCameraPermission()) {
            startPreview()
        } else {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onResume() {
        super.onResume()
        if (hasCameraPermission()) startPreview()
    }

    override fun onPause() {
        if (previewStarted) {
            barcodeView.pause()
            previewStarted = false
        }
        super.onPause()
    }

    private fun startPreview() {
        if (previewStarted) return
        barcodeView.resume()
        previewStarted = true
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        const val EXTRA_RESULT = "com.wootodo.extra.SYNC_SCAN_RESULT"
    }
}
