package pro.momin.localmind

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.Path
import android.hardware.HardwareBuffer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
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
