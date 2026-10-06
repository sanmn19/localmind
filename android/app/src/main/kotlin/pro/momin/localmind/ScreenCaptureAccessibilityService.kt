package pro.momin.localmind

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Display
import java.io.File
import java.io.FileOutputStream

/**
 * Accessibility service whose sole purpose is to let the app capture the
 * current screen for the Android assistant flow without a per-capture
 * MediaProjection consent dialog. The user enables it once under
 * Settings > Accessibility.
 */
class ScreenCaptureAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "Screen capture accessibility service connected")
        instance = this
    }

    override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        Log.i(TAG, "Screen capture accessibility service unbound")
        instance = null
        return super.onUnbind(intent)
    }

    /**
     * Captures the default display and saves it as a PNG inside the app's
     * cache directory, invoking [onResult] with the absolute file path or
     * null when capture is impossible or fails.
     */
    fun captureCurrentScreen(onResult: (String?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            Log.w(TAG, "Screen capture needs Android 11+ (API ${Build.VERSION.SDK_INT})")
            onResult(null)
            return
        }
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshotResult: ScreenshotResult) {
                    val path = saveScreenshot(
                        screenshotResult.hardwareBuffer,
                        screenshotResult.colorSpace
                    )
                    Log.i(TAG, "Screen capture success: $path")
                    onResult(path)
                }

                override fun onFailure(errorCode: Int) {
                    Log.w(TAG, "Screen capture failed: $errorCode")
                    onResult(null)
                }
            }
        )
    }

    private fun saveScreenshot(
        hardwareBuffer: HardwareBuffer,
        colorSpace: ColorSpace
    ): String? {
        return try {
            val hardwareBitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace) ?: return null
            val bitmap = hardwareBitmap.copy(Bitmap.Config.ARGB_8888, false)
            hardwareBitmap.recycle()
            if (bitmap == null) return null

            val dir = File(cacheDir, ASSISTANT_SCREENSHOTS_DIR)
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, "assistant_${System.currentTimeMillis()}.png")

            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            bitmap.recycle()
            file.absolutePath
        } catch (error: Exception) {
            Log.w(TAG, "Assistant screen capture save failed: $error")
            null
        } finally {
            hardwareBuffer.close()
        }
    }

    companion object {
        private const val TAG = "LocalMindCapture"
        private const val ASSISTANT_SCREENSHOTS_DIR = "assistant_screenshots"

        /** Set while the service is connected, cleared on unbind. */
        @JvmStatic
        @Volatile
        var instance: ScreenCaptureAccessibilityService? = null
            private set
    }
}
