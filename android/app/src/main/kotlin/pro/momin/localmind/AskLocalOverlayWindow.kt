package pro.momin.localmind

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Single floating "Ask Local" card host: mounts a FlutterView (backed by ONE
 * long-lived secondary engine running the `askLocalCardMain` entrypoint) in
 * the WindowManager as a TYPE_APPLICATION_OVERLAY window. The window is
 * deliberately dumb — mount/layout/close only; payload delivery and card
 * content live on the `localmind/ask_local` channel (Task 4's notifier) and
 * inside the card isolate itself.
 *
 * Engine caching reopens over the SAME engine (fast reopen, no re-hot-VM
 * spawn); the VIEW is rebuilt per open since WindowManager views are one
 * shot. Removals that did NOT come from a Dart close request fire
 * [NativeAskLocalSink.onCardClosed] so the app side can reap its state.
 */
object AskLocalOverlayWindow {

    private const val TAG = "LocalMindAskLocal"

    /** Card-isolate-only control channel: the card view self-sizes and
     *  self-closes through it (main-engine Dart never drives these). */
    const val CARD_CHANNEL = "localmind/ask_local_card"

    private const val ENTRYPOINT = "askLocalCardMain"
    private const val MAX_WIDTH_DP = 420f
    private const val MIN_WIDTH_DP = 240f
    private const val EDGE_DP = 8f
    private const val HEIGHT_FRACTION = 0.38f
    private const val INITIAL_HEIGHT_DP = 96f
    private const val RESIZE_FLOOR_DP = 64f

    private val mainHandler = Handler(Looper.getMainLooper())

    private var cardEngine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var root: FrameLayout? = null
    private var windowManager: WindowManager? = null
    private var maxHeightPx: Int = 0
    private var isShownValue: Boolean = false

    /** True while the overlay card actually sits on the WindowManager. */
    val isShown: Boolean
        get() = isShownValue

    /**
     * Mounts the card after verifying the overlay permission. Channel
     * callers are already on main; a stray background caller is parked onto
     * main and reports not-shown-yet (callers re-probe `isCardShown`).
     */
    fun show(context: Context, capturePath: String?, selectedText: String): Boolean {
        if (!Settings.canDrawOverlays(context)) {
            Log.w(TAG, "Overlay show skipped: display-over-apps not granted")
            return false
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "Overlay show asked off the main thread; parking on main")
            mainHandler.post { show(context, capturePath, selectedText) }
            return false
        }
        if (isShownValue) return true
        val app = context.applicationContext
        val engine = ensureCardEngine(app) ?: return false
        try {
            attachWindow(app, engine)
        } catch (error: Exception) {
            Log.w(TAG, "Overlay attach failed: $error")
            return false
        }
        // The payload itself re-pushes through the `localmind/ask_local`
        // channel into the live card isolate (Task 4's notifier); the
        // window host only carries the opening hand-off for T4 to request.
        registerCardControls(engine, capturePath, selectedText)
        Log.i(TAG, "Ask Local card shown (entrypoint=$ENTRYPOINT)")
        return true
    }

    /** Content-height resize requested by the card view itself; clamped to
     *  the 38%-of-display ceiling the mount guarantees. */
    fun resizeByContent(heightDp: Float): Boolean {
        if (!isShownValue) return false
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { resizeByContent(heightDp) }
            return true
        }
        val view = root ?: return false
        val density = view.resources.displayMetrics.density
        val wanted = (heightDp * density).toInt()
            .coerceAtLeast((RESIZE_FLOOR_DP * density).toInt())
            .coerceAtMost(maxHeightPx)
        val wm = windowManager ?: return false
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return false
        if (params.height == wanted) return true
        params.height = wanted
        return try {
            wm.updateViewLayout(view, params)
            true
        } catch (error: Exception) {
            Log.w(TAG, "Overlay resize failed: $error")
            false
        }
    }

    /**
     * Removes the card. [closedByRequest] marks closes the Dart side itself
     * initiated (main-channel `closeCard` or the card's own X) — those do
     * NOT echo the closed event back; system-forced teardown (permission
     * revoke, window token gone) does, so Dart can reap its state.
     */
    fun close(closedByRequest: Boolean): Boolean {
        if (!isShownValue) return false
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { close(closedByRequest) }
            return true
        }
        isShownValue = false
        detachWindow()
        Log.i(TAG, "Ask Local card closed (byRequest=$closedByRequest)")
        if (!closedByRequest) NativeAskLocalSink.onCardClosed?.invoke()
        return true
    }

    /** Secondary engine: created once, reused across open/close cycles.
     *  Plugin auto-registration stays OFF — the card isolate is minimally
     *  bootstrapped (Task 4) and shared single-instanced plugins must not
     *  double-register against the main engine. */
    private fun ensureCardEngine(context: Context): FlutterEngine? {
        cardEngine?.let { return it }
        return try {
            val appBundlePath = FlutterInjector.instance()
                .flutterLoader()
                .findAppBundlePath()
            val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, ENTRYPOINT)
            val options = FlutterEngineGroup.Options(context)
                .setDartEntrypoint(entrypoint)
                .setAutomaticallyRegisterPlugins(false)
            FlutterEngineGroup(context).createAndRunEngine(options).also {
                cardEngine = it
                Log.i(TAG, "Ask Local card engine started")
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Ask Local card engine failed to boot: $error")
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun attachWindow(context: Context, engine: FlutterEngine) {
        val metrics = displayMetrics(context)
        val density = metrics.density
        val edgePx = (EDGE_DP * density).toInt()
        maxHeightPx = (metrics.heightPixels * HEIGHT_FRACTION).toInt()
        val widthPx = (MAX_WIDTH_DP * density).toInt()
            .coerceAtLeast((MIN_WIDTH_DP * density).toInt())
            .coerceAtMost((metrics.widthPixels - edgePx * 2).coerceAtLeast((MIN_WIDTH_DP * density).toInt()))
        val heightPx = (INITIAL_HEIGHT_DP * density).toInt().coerceAtMost(maxHeightPx)

        val card = FlutterView(context, RenderMode.texture, TransparencyMode.transparent)
            .also { it.attachToFlutterEngine(engine) }
        val container = object : FrameLayout(context) {
            override fun onDetachedFromWindow() {
                // System-initiated teardown (permission revoke / token gone):
                // reap as an externally-closed card.
                if (isShownValue) {
                    isShownValue = false
                    flutterView?.detachFromFlutterEngine()
                    flutterView = null
                    root = null
                    NativeAskLocalSink.onCardClosed?.invoke()
                }
                super.onDetachedFromWindow()
            }
        }.apply {
            addView(card, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ))
        }

        val params = WindowManager.LayoutParams(
            widthPx,
            heightPx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = edgePx
            y = edgePx
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        wm.addView(container, params)
        windowManager = wm
        root = container
        flutterView = card
        isShownValue = true
    }

    private fun detachWindow() {
        val view = root
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        root = null
        view?.let {
            try {
                windowManager?.removeView(it)
            } catch (error: Exception) {
                Log.w(TAG, "Overlay remove failed: $error")
            }
        }
    }

    /** Card-isolate control channel: resize to the measured content height,
     *  the card's own close, and the opening hand-off the T4 card asks for
     *  once its UI is materialised. */
    private fun registerCardControls(
        engine: FlutterEngine,
        capturePath: String?,
        selectedText: String
    ) {
        io.flutter.plugin.common.MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CARD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "resizeFloatingCard" -> {
                    val height = (call.argument<Any?>("height") as? Number)?.toFloat() ?: 0f
                    result.success(resizeByContent(height))
                }
                "closeCard" -> result.success(close(closedByRequest = true))
                "getInitialPayload" -> result.success(
                    mapOf(
                        "capturePath" to capturePath,
                        "selectedText" to selectedText
                    )
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun displayMetrics(context: Context): DisplayMetrics {
        val base = context.resources.displayMetrics
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val bounds = wm.maximumWindowMetrics.bounds
            DisplayMetrics().apply {
                density = base.density
                densityDpi = base.densityDpi
                widthPixels = bounds.width()
                heightPixels = bounds.height()
            }
        } else {
            DisplayMetrics().also { metrics ->
                val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                wm.defaultDisplay.getRealMetrics(metrics)
            }
        }
    }
}
