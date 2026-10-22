package pro.momin.localmind

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.Path
import android.hardware.HardwareBuffer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.File
import java.io.FileOutputStream

/**
 * Accessibility service whose purpose is to let the app capture the current
 * screen for the Android assistant flow, plus tool-run screenshot requests
 * (`apps.screenshot`), without a per-capture MediaProjection consent dialog.
 * The user enables it once under Settings > Accessibility.
 */
class ScreenCaptureAccessibilityService : AccessibilityService() {

    private val mainHandler = Handler(Looper.getMainLooper())

    // Event-driven screen-memory sampling. The accessibility event is the
    // trigger; a short debounce coalesces content-change bursts into one read.
    private val sampleRing = ArrayDeque<ScreenTextSample>()
    private var samplingEnabled = false
    private var sampleIntervalMs = 500L
    private var screenOn = true
    private var lastSampleSignature: String? = null
    private val debounceSample = Runnable { captureSample() }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOn = false
                    mainHandler.removeCallbacks(debounceSample)
                }
                Intent.ACTION_SCREEN_ON -> {
                    screenOn = true
                    scheduleSample()
                }
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "Screen capture accessibility service connected")
        instance = this
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        screenOn = power?.isInteractive == true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        registerReceiver(screenReceiver, filter)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!samplingEnabled) return
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> scheduleSample()
        }
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        Log.i(TAG, "Screen capture accessibility service unbound")
        stopSampling()
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered (service re-created).
        }
        instance = null
        return super.onUnbind(intent)
    }

    /** Starts event-driven sampling with [intervalMs] debounce. */
    fun startSampling(intervalMs: Long) {
        samplingEnabled = true
        sampleIntervalMs = intervalMs.coerceIn(MIN_SAMPLE_INTERVAL_MS, MAX_SAMPLE_INTERVAL_MS)
        scheduleSample()
    }

    /** Stops sampling and drops any queued text. */
    fun stopSampling() {
        samplingEnabled = false
        mainHandler.removeCallbacks(debounceSample)
        sampleRing.clear()
        lastSampleSignature = null
    }

    /** Drains and clears the queued samples for the Dart batch. */
    fun drainSamples(): List<Map<String, Any>> {
        val out = sampleRing.map {
            mapOf(
                "packageName" to it.packageName,
                "text" to it.text,
                "capturedAtMillis" to it.capturedAtMillis
            )
        }
        sampleRing.clear()
        return out
    }

    /** Number of changed-screen samples waiting for the next batch. */
    fun pendingSampleCount(): Int = sampleRing.size

    private fun scheduleSample() {
        if (!samplingEnabled || !screenOn) return
        mainHandler.removeCallbacks(debounceSample)
        mainHandler.postDelayed(debounceSample, sampleIntervalMs)
    }

    private fun captureSample() {
        if (!samplingEnabled || !screenOn) return
        val screen = readScreenTextNow() ?: return
        // Cheap dirty check: package + window + text fingerprint. The event
        // already told us something changed, but a burst of layout events can
        // still resolve to the same text.
        val signature = "${screen.packageName}|${screen.windowId}|${screen.text.hashCode()}"
        if (signature == lastSampleSignature) return
        lastSampleSignature = signature
        sampleRing.addLast(
            ScreenTextSample(
                packageName = screen.packageName,
                text = screen.text,
                capturedAtMillis = System.currentTimeMillis()
            )
        )
        while (sampleRing.size > MAX_SAMPLE_RING) {
            sampleRing.removeFirst()
        }
    }

    /**
     * Captures the default display and saves it as a PNG inside the app's
     * cache directory, invoking [onResult] with the absolute file path or
     * null when capture is impossible or fails.
     */
    fun captureCurrentScreen(onResult: (String?) -> Unit) {
        captureScreenTo(ASSISTANT_SCREENSHOTS_DIR, "assistant", onResult)
    }

    /** [captureCurrentScreen] with a caller-chosen cache sub-directory and
     *  file prefix; the `apps.screenshot` tool keeps its captures inside
     *  [TOOL_SCREENSHOTS_DIR] so they stay disposable, away from the
     *  assistant flow's stash. */
    fun captureScreenTo(dirName: String, prefix: String, onResult: (String?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            Log.w(TAG, "Screen capture needs Android 11+ (API ${Build.VERSION.SDK_INT})")
            onResult(null)
            return
        }
        captureBitmap { bitmap ->
            if (bitmap == null) {
                onResult(null)
                return@captureBitmap
            }
            val path = saveBitmap(bitmap, dirName, prefix)
            Log.i(TAG, "Screen capture success: $path")
            bitmap.recycle()
            onResult(path)
        }
    }

    /**
     * Scroll-and-stitch capture for `apps.screenshot(scroll: true)`:
     * repeated captures separated by a swipe-up gesture, until a sampled
     * pixel hash shows the content stopped moving (or the sanity cap or a
     * failed gesture ends the loop). The frames are then stitched
     * overlap-aware via row-hash alignment into ONE tall PNG. [onResult]
     * receives the file path plus how many frames made it into the image
     * (null path = capture failed).
     */
    fun captureScrollingScreens(onResult: (path: String?, frames: Int) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            Log.w(TAG, "Scroll capture needs Android 11+ (API ${Build.VERSION.SDK_INT})")
            onResult(null, 0)
            return
        }
        val frames = mutableListOf<Bitmap>()

        fun finalize() {
            if (frames.isEmpty()) {
                onResult(null, 0)
                return
            }
            val count = frames.size
            val stitched = stitchFrames(frames)
            frames.forEach { it.recycle() }
            if (stitched == null) {
                onResult(null, 0)
                return
            }
            val path = saveBitmap(stitched, TOOL_SCREENSHOTS_DIR, "tool")
            Log.i(TAG, "Scroll capture stitched $count frames into $path")
            stitched.recycle()
            onResult(path, count)
        }

        fun captureNext(previousHash: IntArray?) {
            captureBitmap { bitmap ->
                if (bitmap == null) {
                    finalize()
                    return@captureBitmap
                }
                val hash = frameSampleHash(bitmap) ?: run {
                    bitmap.recycle()
                    finalize()
                    return@captureBitmap
                }
                frames.add(bitmap)
                if (previousHash != null && previousHash.contentEquals(hash)) {
                    // The swipe produced no scroll progress — the content
                    // has ended, so stop before further gestures.
                    Log.i(TAG, "Scroll capture ended after ${frames.size} frames (no movement)")
                    finalize()
                    return@captureBitmap
                }
                if (frames.size >= MAX_SCROLL_FRAMES) {
                    Log.i(TAG, "Scroll capture sanity cap reached (${frames.size} frames)")
                    finalize()
                    return@captureBitmap
                }
                if (!dispatchSwipeUp()) {
                    Log.w(TAG, "Swipe gesture refused; stitching what was captured")
                    finalize()
                    return@captureBitmap
                }
                mainHandler.postDelayed({ captureNext(hash) }, SCROLL_SETTLE_MS)
            }
        }

        captureNext(null)
    }

    /**
     * Reads the visible text of the foreground app for the screen-memory
     * sampler. Null while the screen is off or locked, when no readable
     * window belongs to another app, and when the readable window carries no
     * text. Only the active/focused window is read, so a window behind it (a
     * blocked app, say) can never contribute text. Password fields (and their
     * subtrees), LocalMind's own windows, keyboards, and the system UI are
     * skipped; the collected text is capped at [MAX_SCREEN_TEXT_CHARS].
     */
    fun readScreenText(onResult: (ScreenText?) -> Unit) {
        onResult(readScreenTextNow())
    }

    /** One synchronous read of the active/focused window, or null. */
    private fun readScreenTextNow(): ScreenText? {
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val interactive = powerManager?.isInteractive == true
        if (!interactive || keyguardManager?.isKeyguardLocked == true) {
            Log.i(TAG, "Screen text read skipped: interactive=$interactive")
            return null
        }

        // The active/focused window only: a window behind it (for example a
        // blocked app under an overlay) must not contribute its package or text.
        val root = rootInActiveWindow
            ?: windows.orEmpty().firstOrNull { it.isFocused || it.isActive }?.root
        val packageName = root?.packageName?.toString()
        if (root == null || packageName == null || isSkippedPackage(packageName)) {
            Log.i(TAG, "Screen text read found nothing (package=$packageName)")
            return null
        }

        val collected = StringBuilder()
        collectNodeText(root, collected)
        val text = collected.take(MAX_SCREEN_TEXT_CHARS).toString()
        if (text.isBlank()) {
            Log.i(TAG, "Screen text read found nothing (package=$packageName)")
            return null
        }
        return ScreenText(
            packageName = packageName,
            text = text,
            isInteractive = interactive,
            windowId = root.windowId
        )
    }

    /** Own windows, keyboards, and the system UI never describe the user's
     *  foreground app, so their text is skipped. */
    private fun isSkippedPackage(packageName: String): Boolean {
        if (packageName == this.packageName || packageName == SYSTEM_UI_PACKAGE) {
            return true
        }
        return KEYBOARD_PACKAGE_PREFIXES.any { packageName.startsWith(it) }
    }

    /** Depth-first walk in reading order; password nodes take their whole
     *  subtree with them, and collection stops at the character cap. Nodes are
     *  recycled after use on API 26-32; recycle is a no-op from API 33. */
    private fun collectNodeText(root: AccessibilityNodeInfo, out: StringBuilder) {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        try {
            while (stack.isNotEmpty() && out.length < MAX_SCREEN_TEXT_CHARS) {
                val node = stack.removeLast()
                try {
                    if (!node.isPassword) {
                        val nodeText = node.text
                        appendNodeText(out, nodeText)
                        val description = node.contentDescription
                        if (description != null && description.toString() != nodeText?.toString()) {
                            appendNodeText(out, description)
                        }
                        for (index in node.childCount - 1 downTo 0) {
                            node.getChild(index)?.let(stack::addLast)
                        }
                    }
                } finally {
                    recycleNode(node)
                }
            }
        } finally {
            // The character cap can leave acquired nodes on the stack.
            while (stack.isNotEmpty()) {
                recycleNode(stack.removeLast())
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun recycleNode(node: AccessibilityNodeInfo) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            node.recycle()
        }
    }

    private fun appendNodeText(out: StringBuilder, value: CharSequence?) {
        val text = value?.toString()?.trim()
        if (text.isNullOrEmpty()) return
        if (out.isNotEmpty()) out.append('\n')
        out.append(text)
    }

    /**
     * One `takeScreenshot` round delivering a software-copied ARGB bitmap
     * (or null). Runs on the main thread both ways.
     */
    private fun captureBitmap(onBitmap: (Bitmap?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onBitmap(null)
            return
        }
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshotResult: ScreenshotResult) {
                    onBitmap(
                        decodeScreenshot(
                            screenshotResult.hardwareBuffer,
                            screenshotResult.colorSpace
                        )
                    )
                }

                override fun onFailure(errorCode: Int) {
                    Log.w(TAG, "Screen capture failed: $errorCode")
                    onBitmap(null)
                }
            }
        )
    }

    private fun decodeScreenshot(
        hardwareBuffer: HardwareBuffer,
        colorSpace: ColorSpace
    ): Bitmap? {
        return try {
            val hardwareBitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace) ?: return null
            val bitmap = hardwareBitmap.copy(Bitmap.Config.ARGB_8888, false)
            hardwareBitmap.recycle()
            if (bitmap == null) {
                Log.w(TAG, "Screenshot copy to ARGB_8888 failed")
            }
            bitmap
        } catch (error: Exception) {
            Log.w(TAG, "Screenshot decode failed: $error")
            null
        } finally {
            hardwareBuffer.close()
        }
    }

    private fun saveBitmap(
        bitmap: Bitmap,
        dirName: String,
        prefix: String
    ): String? {
        return try {
            val dir = File(cacheDir, dirName)
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, "${prefix}_${System.currentTimeMillis()}.png")

            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            file.absolutePath
        } catch (error: Exception) {
            Log.w(TAG, "Screen capture save failed: $error")
            null
        }
    }

    /**
     * Swipes up mid-screen to scroll the content one step. Requires the
     * service config's `canPerformGestures`; a false return reports the
     * refusal so the caller can finalize instead of looping forever.
     */
    private fun dispatchSwipeUp(): Boolean {
        val width = resources.displayMetrics.widthPixels
        val height = resources.displayMetrics.heightPixels
        val path = Path().apply {
            moveTo(width * 0.5f, height * 0.72f)
            lineTo(width * 0.5f, height * 0.24f)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, SCROLL_SWIPE_DURATION_MS))
            .build()
        return dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) = Unit

                override fun onCancelled(gestureDescription: GestureDescription?) = Unit
            },
            mainHandler
        )
    }

    /**
     * Overlap-aware stitch: aligns each later frame against the accumulated
     * canvas by matching averaged row fingerprints across a bounded search
     * window, then appends only the non-overlapped rows. A frame with no
     * verifiable overlap row ends the stitch — appending unaligned content
     * would corrupt the image — and whatever accumulated so far is returned
     * (null when nothing could be built).
     */
    private fun stitchFrames(frames: List<Bitmap>): Bitmap? {
        if (frames.isEmpty()) return null
        val first = frames.first()
        var canvas = Bitmap.createBitmap(first.width, first.height, Bitmap.Config.ARGB_8888)
        Canvas(canvas).drawBitmap(first, 0f, 0f, null)
        var canvasHashes = rowHashes(canvas, 0, canvas.height)

        for (next in frames.drop(1)) {
            val nextHashes = rowHashes(next, 0, next.height)
            val overlap = findOverlapRows(canvasHashes, nextHashes)
            if (overlap == null) break
            val appendHeight = next.height - overlap
            if (appendHeight <= 0) continue

            val combined = Bitmap.createBitmap(
                canvas.width,
                canvas.height + appendHeight,
                Bitmap.Config.ARGB_8888
            )
            val drawCanvas = Canvas(combined)
            drawCanvas.drawBitmap(canvas, 0f, 0f, null)
            // Seam: place `next` so its leading `overlap` rows line up with
            // the canvas's trailing rows — new content appends BELOW, never
            // overwrites what's already stitched.
            drawCanvas.drawBitmap(
                next,
                0f,
                (canvas.height - overlap).toFloat(),
                null
            )
            canvas.recycle()
            canvas = combined

            canvasHashes = canvasHashes + rowHashes(next, overlap, next.height)
        }
        return canvas
    }

    /**
     * Bottom-anchored overlap search: the next frame's [offset] leading rows
     * must equal the accumulated canvas's trailing rows. Candidates are
     * checked with a few spread probe rows first; a probe hit is verified
     * across the whole band before being accepted.
     */
    private fun findOverlapRows(currentHashes: IntArray, nextHashes: IntArray): Int? {
        val searchLimit = minOf(
            SCROLL_OVERLAP_SEARCH_PX,
            minOf(currentHashes.size, nextHashes.size) - 1
        )
        for (offset in 1..searchLimit) {
            var matched = true
            for (probe in intArrayOf(0, offset / 2, offset - 1)) {
                if (currentHashes[currentHashes.size - offset + probe] != nextHashes[probe]) {
                    matched = false
                    break
                }
            }
            if (!matched) continue
            for (row in 0 until offset) {
                if (currentHashes[currentHashes.size - offset + row] != nextHashes[row]) {
                    matched = false
                    break
                }
            }
            if (matched) return offset
        }
        return null
    }

    companion object {
        private const val TAG = "LocalMindCapture"
        private const val ASSISTANT_SCREENSHOTS_DIR = "assistant_screenshots"

        /** Cache sub-directory for tool-run (`apps.screenshot`) captures. */
        const val TOOL_SCREENSHOTS_DIR = "tool_screenshots"

        /** Sanity cap on the scroll loop: at most this many frames stitch. */
        private const val MAX_SCROLL_FRAMES = 6

        /** Wait for the next render between a swipe and the re-capture. */
        private const val SCROLL_SETTLE_MS = 900L

        /** Duration of one swipe-up gesture stroke. */
        private const val SCROLL_SWIPE_DURATION_MS = 220L

        /** Sampled pixels per frame for the identical-frame end detect. */
        private const val SCROLL_HASH_SAMPLES = 400

        /** Row-coverage search window (px) when aligning a stitch overlap. */
        private const val SCROLL_OVERLAP_SEARCH_PX = 140

        /** Stride of the row-average pixel sampling for stitch alignment. */
        private const val SCROLL_ROW_SAMPLE_STRIDE = 4

        /** Character cap on one foreground-app text read. */
        private const val MAX_SCREEN_TEXT_CHARS = 8000

        /** Bounded in-memory queue drained by the Dart batch. */
        private const val MAX_SAMPLE_RING = 200

        /** Debounce bounds for event-driven sampling. */
        private const val MIN_SAMPLE_INTERVAL_MS = 250L
        private const val MAX_SAMPLE_INTERVAL_MS = 5000L

        /** System UI windows never count as the foreground app. */
        private const val SYSTEM_UI_PACKAGE = "com.android.systemui"

        /** Keyboard windows never count as the foreground app. */
        private val KEYBOARD_PACKAGE_PREFIXES = listOf(
            "com.google.android.inputmethod",
            "com.android.inputmethod"
        )

        /**
         * Set while the service is connected, cleared on unbind.
         */
        @JvmStatic
        @Volatile
        var instance: ScreenCaptureAccessibilityService? = null
            private set

        /**
         * Samples a spread of [SCROLL_HASH_SAMPLES] pixels across the frame
         * (a fixed-grid blob fingerprint). Two frames hashing equal means
         * the screen content did not move between captures.
         */
        fun frameSampleHash(bitmap: Bitmap): IntArray? {
            val width = bitmap.width
            val height = bitmap.height
            if (width <= 0 || height <= 0) return null
            val cols = 20
            val rows = SCROLL_HASH_SAMPLES / cols
            val samples = IntArray(rows * cols)
            for (row in 0 until rows) {
                val y = (((row + 0.5f) * height / rows).toInt()).coerceIn(0, height - 1)
                for (col in 0 until cols) {
                    val x = (((col + 0.5f) * width / cols).toInt()).coerceIn(0, width - 1)
                    samples[row * cols + col] = bitmap.getPixel(x, y)
                }
            }
            return samples
        }

        /**
         * Per-row average-color fingerprints (pixels sampled every 4th x) of
         * the [fromRow, toRow) band, used as the stitch alignment key.
         */
        fun rowHashes(bitmap: Bitmap, fromRow: Int, toRow: Int): IntArray {
            val rows = toRow - fromRow
            val hashes = IntArray(maxOf(0, rows))
            if (rows <= 0) return hashes
            val width = bitmap.width
            val pixelRow = IntArray(width)
            for ((index, y) in (fromRow until toRow).withIndex()) {
                bitmap.getPixels(pixelRow, 0, width, 0, y, width, 1)
                var r = 0L
                var g = 0L
                var b = 0L
                var count = 0
                var x = 0
                while (x < width) {
                    val color = pixelRow[x]
                    r += Color.red(color)
                    g += Color.green(color)
                    b += Color.blue(color)
                    count++
                    x += SCROLL_ROW_SAMPLE_STRIDE
                }
                hashes[index] = Color.rgb(
                    (r / count).toInt(),
                    (g / count).toInt(),
                    (b / count).toInt()
                )
            }
            return hashes
        }
    }
}

/** One on-demand foreground-app text read: the app that owned the window,
 *  the concatenated visible text, and whether the screen was on and unlocked. */
data class ScreenText(
    val packageName: String,
    val text: String,
    val isInteractive: Boolean,
    val windowId: Int
)

/** One changed-screen sample waiting for the Dart batch. */
data class ScreenTextSample(
    val packageName: String,
    val text: String,
    val capturedAtMillis: Long
)
