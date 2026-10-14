package pro.momin.localmind

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * PROCESS_TEXT target for the system text-selection overflow ("Ask Local").
 * Extracts EXTRA_PROCESS_TEXT, asks [ScreenCaptureAccessibilityService] for
 * ONE frame of the screen the selection was made on — the capture request
 * fires before anything else, so the bitmap predates this activity's own
 * surface — and hands {capturePath, selectedText} to [NativeAskLocalSink],
 * which routes into MainActivity's `localmind/ask_local` channel. The
 * activity is translucent, history-free and finishes as soon as the capture
 * resolves (a capture failure just delivers a null capturePath: the card
 * still opens, minus the thumbnail).
 */
class AskLocalTextActivity : Activity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var settled = false
    private var timeout: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val selected = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
        val text = selected?.toString() ?: ""
        if (text.isBlank()) {
            Log.i(TAG, "PROCESS_TEXT payload empty; ignoring")
            finish()
            return
        }

        val service = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ScreenCaptureAccessibilityService.instance
        } else {
            null
        }
        Log.i(TAG, "Ask Local capture requested; service bound: ${service != null}")
        if (service == null) {
            deliverOnce(null, text)
            return
        }
        service.captureScreenTo(ASK_LOCAL_SCREENSHOTS_DIR, "ask_local") { path ->
            deliverOnce(path, text)
        }
        timeout = Runnable {
            Log.w(TAG, "Ask Local screen capture timed out")
            deliverOnce(null, text)
        }.also { mainHandler.postDelayed(it, CAPTURE_TIMEOUT_MS) }
    }

    /** Single-shot hand-off: submit to the sink, decline the text
     *  replacement (RESULT_CANCELED keeps the host's selection) and finish
     *  without a visible window of our own. */
    private fun deliverOnce(capturePath: String?, selectedText: String) {
        if (settled) return
        settled = true
        timeout?.let { mainHandler.removeCallbacks(it) }
        timeout = null
        NativeAskLocalSink.submit(
            mapOf(
                "selectedText" to selectedText,
                "capturePath" to capturePath
            )
        )
        setResult(Activity.RESULT_CANCELED)
        finish()
    }

    companion object {
        private const val TAG = "LocalMindAskLocal"
        private const val CAPTURE_TIMEOUT_MS = 2000L
        const val ASK_LOCAL_SCREENSHOTS_DIR = "ask_local_screenshots"
    }
}
