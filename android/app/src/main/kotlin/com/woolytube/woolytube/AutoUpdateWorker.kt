package com.woolytube.woolytube

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class AutoUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "WoolyTube.AutoUpdate"
        const val INPUT_ALLOW_MOBILE_DATA = "allow_mobile_data"
    }

    override suspend fun doWork(): Result {
        return withContext(Dispatchers.Main) {
            try {
                val allowMobileData = inputData.getBoolean(
                    INPUT_ALLOW_MOBILE_DATA,
                    false
                )
                if (!allowMobileData && isUsingMobileData()) {
                    Log.i(TAG, "Skipping auto-update on mobile data")
                    return@withContext Result.success()
                }

                Log.i(TAG, "Starting auto-update check")

                val flutterLoader = FlutterLoader()
                flutterLoader.startInitialization(applicationContext)
                flutterLoader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)

                // Set up a method channel so the Dart side can signal completion
                val latch = CountDownLatch(1)
                var taskResult = Result.success()

                val controlChannel = MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    "com.woolytube/background"
                )
                controlChannel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "taskComplete" -> {
                            Log.i(TAG, "Auto-update completed successfully")
                            result.success(null)
                            latch.countDown()
                        }
                        "taskFailed" -> {
                            Log.w(TAG, "Auto-update failed: ${call.argument<String>("error")}")
                            taskResult = Result.retry()
                            result.success(null)
                            latch.countDown()
                        }
                        else -> result.notImplemented()
                    }
                }

                // Execute the background Dart entrypoint
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        flutterLoader.findAppBundlePath(),
                        "backgroundMain"
                    )
                )

                // Wait for completion (max 10 minutes)
                withContext(Dispatchers.IO) {
                    latch.await(10, TimeUnit.MINUTES)
                }

                engine.destroy()
                taskResult
            } catch (e: Exception) {
                Log.e(TAG, "Auto-update worker failed", e)
                Result.retry()
            }
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
