package com.woolytube.woolytube

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The hourly scheduled playlist update.
 *
 * Flutter 3.29 runs Dart on the Android main thread, so a second Flutter
 * engine in this process shares one thread with the app's frames. The worker
 * therefore never starts one while the app's engine is alive: it asks that
 * engine to run the update ("com.woolytube/auto_update", answered by
 * ForegroundAutoUpdateBridge in Dart). A headless engine running
 * `backgroundMain` is used only when the process has no app engine, and it
 * hands over as soon as the app's engine appears.
 *
 * Every run fits WorkManager's ten-minute limit: Dart stops starting work
 * after about 7 minutes and stops the running track at about 8.5. Whatever
 * happens, including WorkManager stopping the worker, the headless engine is
 * destroyed and a background lock it left behind is removed.
 */
class AutoUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "WoolyTube.AutoUpdate"
        const val INPUT_ALLOW_MOBILE_DATA = "allow_mobile_data"
        private const val UNIQUE_WORK_NAME = "woolytube_auto_update"

        private const val AUTO_UPDATE_CHANNEL = "com.woolytube/auto_update"
        private const val CONTROL_CHANNEL = "com.woolytube/background"

        /** Total time a run may take, leaving room under WorkManager's 10 min. */
        private val RUN_BUDGET_MS = TimeUnit.SECONDS.toMillis(550L)

        /** How long a stopped run gets to finish its clean-up. */
        private const val STOP_GRACE_MS = 20_000L

        /** How often the headless run checks whether the app engine appeared. */
        private const val APP_ENGINE_POLL_MS = 2_000L
        private const val PING_TIMEOUT_MS = 2_000L

        private const val LOCK_FILE_NAME = "download.lock"
        private const val BACKGROUND_LOCK_OWNER = "background"

        /** The headless engine of the run in progress (main thread only). */
        private var headlessEngine: FlutterEngine? = null

        fun schedule(context: Context, allowMobileData: Boolean) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .build()

            val request = PeriodicWorkRequestBuilder<AutoUpdateWorker>(1, TimeUnit.HOURS)
                .setConstraints(constraints)
                .setInputData(workDataOf(INPUT_ALLOW_MOBILE_DATA to allowMobileData))
                .build()

            WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                UNIQUE_WORK_NAME,
                // Refresh the installed periodic request on every app start so
                // changes to its interval or constraints are not hidden behind an
                // older request left by a previous app version.
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
        }
    }

    private sealed class Reply {
        data class Success(val value: Any?) : Reply()
        data class Error(val message: String?) : Reply()
        object NotImplemented : Reply()
    }

    private enum class Delegation { DONE, FAILED, UNAVAILABLE }

    override suspend fun doWork(): Result {
        val allowMobileData = inputData.getBoolean(INPUT_ALLOW_MOBILE_DATA, false)
        if (!allowMobileData && isUsingMobileData()) {
            Log.i(TAG, "Skipping auto-update on mobile data")
            return Result.success()
        }
        val deadline = SystemClock.elapsedRealtime() + RUN_BUDGET_MS
        return try {
            when (delegateToAppEngine(deadline)) {
                Delegation.DONE -> Result.success()
                Delegation.FAILED -> Result.retry()
                Delegation.UNAVAILABLE -> runHeadless(deadline)
            }
        } catch (e: CancellationException) {
            // WorkManager stopped the worker; the finally blocks below have
            // already stopped the run.
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Auto-update worker failed", e)
            Result.retry()
        }
    }

    private fun remaining(deadline: Long) = deadline - SystemClock.elapsedRealtime()

    /** The app's engine, when its Dart code is running. Main thread only. */
    private fun appEngine(): FlutterEngine? =
        FlutterEngineCache.getInstance()
            .get(AudioServicePlugin.getFlutterEngineId())
            ?.takeIf { it.dartExecutor.isExecutingDart }

    private suspend fun callDart(
        engine: FlutterEngine,
        channelName: String,
        method: String,
        arguments: Any?
    ): CompletableDeferred<Reply> = withContext(Dispatchers.Main) {
        val reply = CompletableDeferred<Reply>()
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, channelName).invokeMethod(
                method,
                arguments,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        reply.complete(Reply.Success(result))
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        reply.complete(Reply.Error(message ?: code))
                    }

                    override fun notImplemented() {
                        reply.complete(Reply.NotImplemented)
                    }
                }
            )
        } catch (e: Exception) {
            reply.complete(Reply.Error(e.message))
        }
        reply
    }

    /** Whether the app engine's Dart side can run the update. */
    private suspend fun appEngineReady(): FlutterEngine? {
        val engine = withContext(Dispatchers.Main) { appEngine() } ?: return null
        val pong = withTimeoutOrNull(PING_TIMEOUT_MS) {
            callDart(engine, AUTO_UPDATE_CHANNEL, "ping", null).await()
        }
        return if (pong is Reply.Success) engine else null
    }

    private suspend fun delegateToAppEngine(deadline: Long): Delegation {
        val engine = appEngineReady() ?: return Delegation.UNAVAILABLE
        val budget = remaining(deadline)
        if (budget <= STOP_GRACE_MS) return Delegation.DONE
        Log.i(TAG, "Running auto-update in the app engine")
        var answered = false
        try {
            val reply = withTimeoutOrNull(budget) {
                callDart(engine, AUTO_UPDATE_CHANNEL, "runAutoUpdate", mapOf("budgetMs" to budget))
                    .await()
            }
            answered = reply != null
            return when (reply) {
                null -> {
                    Log.w(TAG, "App engine did not finish in time; stopping it")
                    stopAppEngineRun(engine)
                    answered = true
                    Delegation.DONE
                }
                is Reply.Success -> {
                    Log.i(TAG, "Auto-update finished: ${reply.value}")
                    val status = (reply.value as? Map<*, *>)?.get("status")
                    if (status == "failed") Delegation.FAILED else Delegation.DONE
                }
                is Reply.Error -> {
                    Log.w(TAG, "Auto-update in the app engine failed: ${reply.message}")
                    Delegation.FAILED
                }
                Reply.NotImplemented -> Delegation.UNAVAILABLE
            }
        } finally {
            if (!answered) {
                // The worker was stopped while the app engine was updating.
                withContext(NonCancellable) { stopAppEngineRun(engine) }
            }
        }
    }

    private suspend fun stopAppEngineRun(engine: FlutterEngine) {
        withTimeoutOrNull(STOP_GRACE_MS) {
            callDart(engine, AUTO_UPDATE_CHANNEL, "stopAutoUpdate", null).await()
        }
    }

    private suspend fun runHeadless(deadline: Long): Result {
        val done = CompletableDeferred<Result>()
        var handOver = false
        val engine = withContext(Dispatchers.Main) {
            if (headlessEngine != null) {
                Log.w(TAG, "A previous background run is still active; skipping")
                return@withContext null
            }
            Log.i(TAG, "Starting headless auto-update engine")
            // The process-wide loader; `new FlutterLoader()` re-initialised
            // the engine's global settings on every run.
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            FlutterEngine(applicationContext).also { created ->
                headlessEngine = created
                MethodChannel(created.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
                    .setMethodCallHandler { call, result ->
                        when (call.method) {
                            "taskComplete" -> {
                                Log.i(TAG, "Auto-update completed: ${call.arguments}")
                                result.success(null)
                                done.complete(Result.success())
                            }
                            "taskFailed" -> {
                                Log.w(TAG, "Auto-update failed: ${call.argument<String>("error")}")
                                result.success(null)
                                done.complete(Result.retry())
                            }
                            else -> result.notImplemented()
                        }
                    }
                created.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain")
                )
            }
        } ?: return Result.success()

        try {
            val result = withTimeoutOrNull(remaining(deadline)) {
                var finished: Result? = null
                while (finished == null && !handOver) {
                    finished = withTimeoutOrNull(APP_ENGINE_POLL_MS) { done.await() }
                    // The user opened the app: its engine takes over, so two
                    // engines never share the main thread for long.
                    if (finished == null && appEngineReady() != null) {
                        handOver = true
                        Log.i(TAG, "App engine appeared; handing the update over")
                    }
                }
                finished
            }
            if (result != null) return result
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                shutDownHeadless(engine, done)
            }
        }
        if (handOver && remaining(deadline) > STOP_GRACE_MS) {
            return when (delegateToAppEngine(deadline)) {
                Delegation.FAILED -> Result.retry()
                else -> Result.success()
            }
        }
        return Result.success()
    }

    /** Stops the headless run if it is still going, then destroys the engine. */
    private suspend fun shutDownHeadless(engine: FlutterEngine, done: CompletableDeferred<Result>) {
        if (!done.isCompleted) {
            try {
                MethodChannel(engine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
                    .invokeMethod("stop", null)
            } catch (e: Exception) {
                Log.w(TAG, "Could not ask the background run to stop", e)
            }
            withTimeoutOrNull(STOP_GRACE_MS) { done.await() }
        }
        val finishedCleanly = done.isCompleted
        try {
            engine.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Destroying the background engine failed", e)
        }
        if (headlessEngine === engine) headlessEngine = null
        if (!finishedCleanly) releaseAbandonedBackgroundLock()
        // The app engine (if any) holds its own database connection; tell it
        // to re-read what this run wrote.
        appEngine()?.let { app ->
            try {
                MethodChannel(app.dartExecutor.binaryMessenger, AUTO_UPDATE_CHANNEL)
                    .invokeMethod("libraryChangedExternally", null)
            } catch (e: Exception) {
                Log.w(TAG, "Could not notify the app engine", e)
            }
        }
    }

    /**
     * A run destroyed before its Dart side finished cannot release its lock,
     * and the app would refuse downloads until it went stale. The lock lives
     * in the directory path_provider calls the documents directory.
     */
    private fun releaseAbandonedBackgroundLock() {
        try {
            val lock = File(applicationContext.getDir("flutter", Context.MODE_PRIVATE), LOCK_FILE_NAME)
            if (!lock.exists()) return
            val owner = lock.readText().trim().split(' ').firstOrNull()
            if (owner == BACKGROUND_LOCK_OWNER && lock.delete()) {
                Log.i(TAG, "Removed the lock of an interrupted background run")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not check the download lock", e)
        }
    }

    private fun isUsingMobileData(): Boolean {
        val connectivityManager = applicationContext.getSystemService(
            Context.CONNECTIVITY_SERVICE
        ) as? ConnectivityManager ?: return false
        val network = connectivityManager.activeNetwork ?: return false
        val capabilities =
            connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }
}
