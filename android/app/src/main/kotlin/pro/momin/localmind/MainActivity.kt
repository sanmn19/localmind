package pro.momin.localmind

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.view.accessibility.AccessibilityManager
import androidx.annotation.NonNull
import android.app.Activity
import android.app.ActivityManager
import android.app.role.RoleManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.content.pm.PackageManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "localmind/chat_background"
    private val MEMORY_CHANNEL = "localmind/device_memory"
    private val ASSISTANT_CHANNEL = "localmind/android_assistant"
    private val DEVICE_TOOLS_CHANNEL = "localmind/device_tools"

    private var assistantChannel: MethodChannel? = null
    private var pendingAssistantInvocation = false
    private var pendingRoleRequest: MethodChannel.Result? = null

    // Assistant screen-capture staging: the capture is requested on the
    // invocation itself so it reflects the screen the assistant was fired
    // from, and the Dart side is told about it once the bitmap is on disk.
    private var assistantScreenshotPath: String? = null
    private var assistantScreenshotAwaited = false
    private var assistantScreenshotTimeout: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureAssistantInvocation(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAssistantInvocation(intent)
        deliverAssistantInvocation()
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    ChatForegroundService.startService(this)
                    result.success(null)
                }
                "stopForeground" -> {
                    ChatForegroundService.stopService(this)
                    result.success(null)
                }
                "startForegroundMic" -> {
                    try {
                        ChatForegroundService.startService(this, "microphone")
                        result.success(null)
                    } catch (error: SecurityException) {
                        result.error(
                            "microphone_permission_required",
                            error.message ?: "Microphone permission is required.",
                            null
                        )
                    } catch (error: IllegalStateException) {
                        result.error(
                            "microphone_service_unavailable",
                            error.message ?: "The microphone service could not start.",
                            null
                        )
                    }
                }
                "stopForegroundMic" -> {
                    ChatForegroundService.stopService(this)
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMemoryInfo" -> {
                    val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val memoryInfo = ActivityManager.MemoryInfo()
                    activityManager.getMemoryInfo(memoryInfo)
                    result.success(
                        mapOf(
                            "totalMemoryMb" to (memoryInfo.totalMem / (1024 * 1024)),
                            "availableMemoryMb" to (memoryInfo.availMem / (1024 * 1024))
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }

        assistantChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ASSISTANT_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingInvocation" -> {
                        val wasPending = pendingAssistantInvocation
                        pendingAssistantInvocation = false
                        if (wasPending && assistantScreenshotAwaited) {
                            // A screenshot capture is still resolving; Dart
                            // waits and the invocation arrives via a later
                            // assistantInvoked push.
                            result.success(mapOf("pending" to true, "screenshotPending" to true))
                        } else {
                            result.success(
                                mapOf(
                                    "pending" to wasPending,
                                    "screenshotPath" to if (wasPending) assistantScreenshotPath else null
                                )
                            )
                        }
                    }
                    "getAssistantStatus" -> result.success(getAssistantStatus())
                    "requestAssistantRole" -> requestAssistantRole(result)
                    "openAssistantSettings" -> {
                        if (openAssistantSettings()) {
                            result.success(null)
                        } else {
                            result.error(
                                "assistant_settings_unavailable",
                                "Android assistant settings are unavailable.",
                                null
                            )
                        }
                    }
                    "isScreenshotCaptureEnabled" ->
                        result.success(isAssistantScreenCaptureEnabled())
                    "openScreenCaptureSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(null)
                        } catch (error: ActivityNotFoundException) {
                            result.error(
                                "accessibility_settings_unavailable",
                                "Accessibility settings are unavailable.",
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_TOOLS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "composeEmail" -> composeDeviceEmail(call, result)
                "openApp" -> openDeviceApp(call, result)
                "listInstalledApps" -> listInstalledDeviceApps(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != ASSISTANT_ROLE_REQUEST_CODE) return

        val result = pendingRoleRequest ?: return
        pendingRoleRequest = null
        result.success(
            resultCode == Activity.RESULT_OK || getAssistantStatus() == "active"
        )
    }

    private fun captureAssistantInvocation(intent: Intent?) {
        if (intent?.action != Intent.ACTION_ASSIST) return
        pendingAssistantInvocation = true
        assistantScreenshotPath = null
        assistantScreenshotAwaited = false
        assistantScreenshotTimeout?.let { mainHandler.removeCallbacks(it) }
        assistantScreenshotTimeout = null

        val service = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ScreenCaptureAccessibilityService.instance
        } else {
            null
        }
        Log.i("LocalMindAssist", "Screen capture requested; service bound: ${service != null}")
        if (service != null) {
            assistantScreenshotAwaited = true
            service.captureCurrentScreen { path ->
                onAssistantScreenshotResolved(path)
            }
            assistantScreenshotTimeout = Runnable {
                if (assistantScreenshotAwaited) {
                    Log.w("LocalMindAssist", "Assistant screen capture timed out")
                    onAssistantScreenshotResolved(null)
                }
            }.also { mainHandler.postDelayed(it, SCREENSHOT_TIMEOUT_MS) }
            return
        }
        // No capture service (disabled or unsupported): deliver without a
        // screenshot path right away.
        deliverAssistantInvocation()
    }

    private fun onAssistantScreenshotResolved(path: String?) {
        assistantScreenshotPath = path
        assistantScreenshotAwaited = false
        assistantScreenshotTimeout?.let { mainHandler.removeCallbacks(it) }
        assistantScreenshotTimeout = null
        deliverAssistantInvocation()
    }

    private fun deliverAssistantInvocation() {
        if (!pendingAssistantInvocation || assistantScreenshotAwaited) return
        val channel = assistantChannel ?: return

        channel.invokeMethod(
            "assistantInvoked",
            mapOf("screenshotPath" to assistantScreenshotPath),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    // The Dart handler echoes a truthy ack. A null reply means
                    // no Dart handler was attached yet; keep the invocation
                    // pending so the app-start `consumePendingInvocation`
                    // pull can still deliver it.
                    if (result != null) {
                        pendingAssistantInvocation = false
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit

                override fun notImplemented() = Unit
            }
        )
    }

    private fun isAssistantScreenCaptureEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val manager = getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (manager == null) return false
        val expected = ComponentName(this, ScreenCaptureAccessibilityService::class.java).flattenToString()
        return manager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .any { it.id == expected }
    }

    private fun getAssistantStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "manual"

        val roleManager = getSystemService(RoleManager::class.java)
        if (!roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
            return "unsupported"
        }
        return if (roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
            "active"
        } else {
            "available"
        }
    }

    private fun requestAssistantRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            if (openAssistantSettings()) {
                result.success(false)
            } else {
                result.error(
                    "assistant_settings_unavailable",
                    "Android assistant settings are unavailable.",
                    null
                )
            }
            return
        }

        val roleManager = getSystemService(RoleManager::class.java)
        if (!roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
            result.success(false)
            return
        }
        if (roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
            result.success(true)
            return
        }
        if (pendingRoleRequest != null) {
            result.error(
                "assistant_role_request_active",
                "An assistant role request is already active.",
                null
            )
            return
        }

        pendingRoleRequest = result
        startActivityForResult(
            roleManager.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT),
            ASSISTANT_ROLE_REQUEST_CODE
        )
    }

    private fun openAssistantSettings(): Boolean {
        val candidates = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
        )

        for (candidate in candidates) {
            try {
                startActivity(candidate)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try the next settings destination.
            }
        }
        return false
    }

    /** Builds the same mailto: intent [composeEmailIntent] does on the Dart
     *  side and hands it to the OS mail app. `to` stays verbatim in the
     *  opaque part; subject/body/cc values are percent-encoded per part with
     *  Dart's Uri.encodeComponent leave-set, and the cc list is comma-joined
     *  with literal separators. */
    private fun composeDeviceEmail(call: MethodCall, result: MethodChannel.Result) {
        val to = call.argument<String>("to") ?: ""
        val subject = call.argument<String>("subject") ?: ""
        val body = call.argument<String>("body") ?: ""
        val cc = call.argument<List<String>>("cc") ?: emptyList()

        val segments = mutableListOf(
            "subject=" + Uri.encode(subject, URI_COMPONENT_LEAVE_CHARS),
            "body=" + Uri.encode(body, URI_COMPONENT_LEAVE_CHARS)
        )
        if (cc.isNotEmpty()) {
            segments.add(
                "cc=" + cc.map { Uri.encode(it.trim(), URI_COMPONENT_LEAVE_CHARS) }
                    .joinToString(",")
            )
        }
        val intent = Intent(
            Intent.ACTION_SENDTO,
            Uri.parse("mailto:$to?${segments.joinToString("&")}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        try {
            startActivity(intent)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("no_mail_app", "No mail app available on this device", null)
        } catch (error: SecurityException) {
            result.error(
                "security_exception",
                error.message ?: "Launching the mail app was not allowed.",
                null
            )
        }
    }

    /** Package names go through the app launcher; anything else that carries
     *  a scheme is treated as a deep link. Unresolvable targets and missing
     *  handlers surface `app_not_installed` in both cases. */
    private fun openDeviceApp(call: MethodCall, result: MethodChannel.Result) {
        val target = call.argument<String>("target") ?: ""
        val launch = if (target.matches(PACKAGE_NAME_PATTERN.toRegex())) {
            packageManager.getLaunchIntentForPackage(target)
        } else {
            val link = Uri.parse(target)
            if (link.scheme.isNullOrBlank()) {
                null
            } else {
                Intent(Intent.ACTION_VIEW, link)
            }
        }

        if (launch == null) {
            result.error(
                "app_not_installed",
                "No app installed for this target: $target",
                null
            )
            return
        }

        try {
            startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error(
                "app_not_installed",
                "No app installed to handle this target: $target",
                null
            )
        } catch (error: SecurityException) {
            result.error(
                "security_exception",
                error.message ?: "Opening this app was not allowed.",
                null
            )
        }
    }

    /** [label, package] rows for the model, ordered alphabetically by label.
     *  Rows without usable metadata (hidden/stripped system components) are
     *  skipped rather than listed with blank names. */
    private fun listInstalledDeviceApps(result: MethodChannel.Result) {
        try {
            val rows = packageManager.getInstalledPackages(0)
                .mapNotNull { info ->
                    val appInfo = info.applicationInfo ?: return@mapNotNull null
                    val label = runCatching {
                        packageManager.getApplicationLabel(appInfo).toString()
                    }.getOrNull() ?: return@mapNotNull null
                    mapOf("label" to label, "package" to info.packageName)
                }
                .sortedBy { (it["label"] ?: "").toString().lowercase() }
            result.success(rows)
        } catch (error: SecurityException) {
            result.error(
                "security_exception",
                error.message ?: "Listing installed apps was not allowed.",
                null
            )
        }
    }

    companion object {
        private const val ASSISTANT_ROLE_REQUEST_CODE = 4101
        private const val SCREENSHOT_TIMEOUT_MS = 2000L
        private const val PACKAGE_NAME_PATTERN = "^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)+\$"
        private const val URI_COMPONENT_LEAVE_CHARS = "-_.!~*'()"
    }
}
