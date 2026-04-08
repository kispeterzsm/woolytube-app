package com.woolytube.woolytube

import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.work.*
import java.util.concurrent.TimeUnit

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val BACKGROUND_CHANNEL = "com.woolytube/background"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(YtDlpPlugin())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleAutoUpdate" -> {
                        scheduleAutoUpdate()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun scheduleAutoUpdate() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<AutoUpdateWorker>(
            1, TimeUnit.HOURS
        )
            .setConstraints(constraints)
            .build()

        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            "woolytube_auto_update",
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
    }
}
