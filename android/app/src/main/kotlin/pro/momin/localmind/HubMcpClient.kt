package pro.momin.localmind

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import dev.mcphub.ipc.IMcpHub
import dev.mcphub.ipc.IResultCallback
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Binder client for the on-device MCP hub.
 *
 * The hub is a bound service, not an HTTP endpoint. This client binds it with
 * [ACTION_BIND], lists its merged tool catalogue, and forwards tool calls.
 * The hub keeps consent in its own UI; this client never grants or bypasses it.
 *
 * Every method channel reply is posted back to the main thread because Flutter
 * requires results on the platform thread. Binder calls themselves run on a
 * background executor so the main thread never waits on the hub.
 */
class HubMcpClient(private val context: Context) {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val callExecutor = Executors.newCachedThreadPool()

    private var hub: IMcpHub? = null
    private var bound = false
    private var connectLatch: CountDownLatch? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            synchronized(lock) {
                hub = service?.let(IMcpHub.Stub::asInterface)
                connectLatch?.countDown()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Keep the binding: Android reconnects a bound service. The next
            // call waits on a fresh latch instead of the already-counted one.
            synchronized(lock) {
                hub = null
                connectLatch = null
            }
        }
    }

    /** Routes one Flutter method call to the matching hub operation. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(result)
            "listTools" -> listTools(result)
            "callTool" -> callTool(call, result)
            "readResource" -> readResource(call, result)
            "close" -> close(result)
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        callExecutor.execute {
            try {
                ensureConnected()
                mainHandler.post {
                    result.success(
                        mapOf(
                            "tools" to true,
                            "resources" to false,
                            "prompts" to false
                        )
                    )
                }
            } catch (error: Exception) {
                Log.w(TAG, "MCP Hub initialize failed: $error")
                mainHandler.post {
                    result.error(
                        HUB_UNAVAILABLE,
                        error.message ?: "MCP Hub is unavailable",
                        null
                    )
                }
            }
        }
    }

    private fun listTools(result: MethodChannel.Result) {
        callExecutor.execute {
            try {
                val catalogue = ensureConnected().listTools()
                mainHandler.post { result.success(catalogue) }
            } catch (error: Exception) {
                Log.w(TAG, "MCP Hub listTools failed: $error")
                mainHandler.post {
                    result.error(
                        HUB_UNAVAILABLE,
                        error.message ?: "MCP Hub is unavailable",
                        null
                    )
                }
            }
        }
    }

    private fun callTool(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name.isNullOrBlank()) {
            result.error(INVALID_ARGUMENTS, "Tool name is required", null)
            return
        }
        val argumentsJson = call.argument<String>("arguments") ?: "{}"

        callExecutor.execute {
            try {
                val hub = ensureConnected()
                val latch = CountDownLatch(1)
                val relay = ResultRelay(latch)
                val callId = hub.callTool(name, argumentsJson, relay)
                if (!latch.await(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                    runCatching { hub.cancelCall(callId) }
                    throw IllegalStateException("MCP Hub tool call timed out")
                }
                if (relay.errorCode != 0) {
                    throw IllegalStateException(
                        relay.errorMessage ?: "MCP Hub tool call failed"
                    )
                }
                val resultJson = relay.resultJson
                    ?: throw IllegalStateException("MCP Hub tool call returned no result")
                mainHandler.post {
                    result.success(
                        mapOf(
                            "resultJson" to resultJson,
                            "body" to relay.body
                        )
                    )
                }
            } catch (error: Exception) {
                Log.w(TAG, "MCP Hub callTool($name) failed: $error")
                mainHandler.post {
                    result.error(
                        HUB_CALL_FAILED,
                        error.message ?: "MCP Hub tool call failed",
                        null
                    )
                }
            }
        }
    }

    /**
     * The hub protocol carries tools only; MCP resources are not part of it.
     * Reply with the protocol's own error so the Dart surface can fail loudly
     * instead of pretending an empty resource exists.
     */
    private fun readResource(call: MethodCall, result: MethodChannel.Result) {
        result.error(
            RESOURCES_UNSUPPORTED,
            "MCP Hub does not expose resources",
            call.argument<String>("uri")
        )
    }

    private fun close(result: MethodChannel.Result) {
        dispose()
        result.success(null)
    }

    /** Unbinds from the hub without a MethodChannel reply. */
    fun dispose() {
        synchronized(lock) {
            hub = null
            connectLatch = null
            if (bound) {
                runCatching { context.unbindService(connection) }
                bound = false
            }
        }
    }

    private fun ensureConnected(): IMcpHub {
        synchronized(lock) { hub }?.let { return it }

        val latch = synchronized(lock) {
            hub?.let { return it }
            val pending = connectLatch ?: CountDownLatch(1).also { connectLatch = it }
            if (!bound) {
                val intent = Intent(ACTION_BIND).apply {
                    component = ComponentName(HUB_PACKAGE, HUB_SERVICE)
                    setPackage(HUB_PACKAGE)
                }
                bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                if (!bound) {
                    connectLatch = null
                    throw IllegalStateException("MCP Hub is not installed")
                }
            }
            pending
        }

        if (!latch.await(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            throw IllegalStateException("MCP Hub did not connect")
        }
        return synchronized(lock) { hub }
            ?: throw IllegalStateException("MCP Hub is not available")
    }

    private class ResultRelay(private val latch: CountDownLatch) :
        IResultCallback.Stub() {
        @Volatile var resultJson: String? = null
        @Volatile var body: String? = null
        @Volatile var errorCode = 0
        @Volatile var errorMessage: String? = null

        override fun onResult(
            callId: String?,
            resultJson: String?,
            body: ParcelFileDescriptor?,
        ) {
            this.resultJson = resultJson
            this.body = body?.let(::readBody)
            latch.countDown()
        }

        override fun onProgress(callId: String?, progressJson: String?) = Unit

        override fun onError(callId: String?, code: Int, message: String?) {
            errorCode = code
            errorMessage = message
            latch.countDown()
        }

        private fun readBody(descriptor: ParcelFileDescriptor): String {
            return try {
                FileInputStream(descriptor.fileDescriptor).use { input ->
                    input.readBytes().toString(Charsets.UTF_8)
                }
            } finally {
                runCatching { descriptor.close() }
            }
        }
    }

    private companion object {
        const val TAG = "LocalMindMcpHub"
        const val HUB_PACKAGE = "dev.mcphub.hub"
        const val HUB_SERVICE = "dev.mcphub.hub.HubService"
        const val ACTION_BIND = "dev.mcphub.hub.BIND"
        const val HUB_UNAVAILABLE = "hub_unavailable"
        const val HUB_CALL_FAILED = "hub_call_failed"
        const val INVALID_ARGUMENTS = "invalid_arguments"
        const val RESOURCES_UNSUPPORTED = "resources_unsupported"
        const val CONNECT_TIMEOUT_SECONDS = 5L
        // The hub's own watchdog is 60 s; wait past it so its timeout wins.
        const val CALL_TIMEOUT_SECONDS = 70L
    }
}
