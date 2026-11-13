# audio_service (WoolyTube copy)

This is audio_service 0.18.18 from pub.dev (MIT, see [LICENSE](./LICENSE)), used through `dependency_overrides` in the app's `pubspec.yaml`. `example/`, `test/`, `analysis_options.yaml` and the upstream README were left out. The commit "TODO #14: Vendor audio_service 0.18.18 unchanged" holds the pristine copy, so `git diff <that commit> -- plugins/audio_service` shows the patch.

## Why it is patched

WoolyTube keeps the media service in the foreground while paused (`androidStopForegroundOnPause: false` in `lib/main.dart`), so a paused song can be resumed from the notification, the lock screen or a headset, even after the app is closed. Upstream 0.18.18 has two problems with that setup:

- **Stopping left a stuck notification.** Stopping playback in the app (swiping the mini player away, deleting the playing song or its playlist) makes the handler publish `idle`, and the plugin's `stop()` then only deactivated the media session and called `stopSelf()`. While the app's activity is still bound to the service, `stopSelf()` does not end it, and Android ignores `cancel()` for a foreground notification. The notification stayed, could not be swiped away, and its buttons did nothing because nothing was queued any more.
- **The CPU was kept awake while paused or stopped.** The wake lock was held for as long as the service was in the foreground. On the owner's phone it had been held for 40 hours.

## Changes from upstream

All changes are in `android/src/main/java/com/ryanheise/audioservice/AudioService.java` and are marked `WoolyTube`. The Dart API is unchanged.

1. `stop()` calls `stopForeground(STOP_FOREGROUND_REMOVE)`, releases the wake lock and resets `notificationCreated` before deactivating the session. The notification goes away even while the activity is bound, and a later `updateNotification()` (for example from late metadata) cannot post it again.
2. `onDestroy()` always uses `STOP_FOREGROUND_REMOVE` instead of `DETACH` when `androidResumeOnClick` is on. A detached notification outlived the released media session, so its buttons were dead. `androidResumeOnClick` still keeps the media button receiver (in `configure`), so a headset press can restart playback after the service is gone.
3. `onCreate()` cancels notification 1124. A new service instance has posted nothing yet, so a notification with that id is an orphan of an earlier instance.
4. While paused, the service stays in the foreground (the notification and its buttons stay, as `lib/main.dart` intends), but `exitPlayingState()` now only keeps the CPU awake for 10 s (`IDLE_WAKE_LOCK_MS`) instead of indefinitely. The grace period covers the short pause between two songs.
5. The wake lock is no longer reference counted, so a timed acquire and an untimed one replace each other. `acquireWakeLock()` always calls `acquire()`, which also cancels a pending timed release.
6. `onPlay`, `onPlayFromMediaId` and `onMediaButtonEvent` hold the CPU awake for 10 s when nothing is playing, so a button pressed while paused (for example a headset click with the screen off, which waits for a possible double click) is handled before the phone sleeps. Playing then takes the untimed lock.
7. `enterPlayingState()` takes the wake lock before `startForegroundService`, so playback keeps the CPU awake even if that call throws.

The app's handler (`lib/services/audio_handler.dart`) also overrides `onNotificationDeleted`, whose default would stop playback and forget the saved session.

## Updating

Copy the new upstream package over this folder (without `example/` and `test/`), then re-apply the changes above. Check upstream's CHANGELOG first: if it fixes `stop()` leaving the foreground, some of them may no longer be needed.

## Exact diff

```diff
diff --git a/android/src/main/java/com/ryanheise/audioservice/AudioService.java b/android/src/main/java/com/ryanheise/audioservice/AudioService.java
--- a/android/src/main/java/com/ryanheise/audioservice/AudioService.java
+++ b/android/src/main/java/com/ryanheise/audioservice/AudioService.java
@@ -60,6 +60,10 @@ public class AudioService extends MediaBrowserServiceCompat {
     private static final String SHARED_PREFERENCES_NAME = "audio_service_preferences";
 
     private static final int NOTIFICATION_ID = 1124;
+    // WoolyTube: how long the CPU is kept awake after playback pauses, or
+    // after a media button arrives while paused. Covers the short pause
+    // between two songs and the time the app needs to act on a button.
+    private static final long IDLE_WAKE_LOCK_MS = 10000;
     private static final int REQUEST_CONTENT_INTENT = 1000;
     public static final String NOTIFICATION_CLICK_ACTION = "com.ryanheise.audioservice.NOTIFICATION_CLICK";
     public static final String CUSTOM_ACTION_STOP = "com.ryanheise.audioservice.action.STOP";
@@ -314,6 +318,11 @@ public class AudioService extends MediaBrowserServiceCompat {
 
         configure(new AudioServiceConfig(getApplicationContext()));
 
+        // WoolyTube: a new service instance has posted nothing yet, so a
+        // notification with our id is an orphan left by an earlier instance.
+        // Its buttons reach no media session, so remove it.
+        getNotificationManager().cancel(NOTIFICATION_ID);
+
         mediaSession.setFlags(MediaSessionCompat.FLAG_HANDLES_QUEUE_COMMANDS);
         PlaybackStateCompat.Builder stateBuilder = new PlaybackStateCompat.Builder()
                 .setActions(AUTO_ENABLED_ACTIONS);
@@ -324,6 +333,9 @@ public class AudioService extends MediaBrowserServiceCompat {
 
         PowerManager pm = (PowerManager)getSystemService(Context.POWER_SERVICE);
         wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, AudioService.class.getName());
+        // WoolyTube: a single lock, so a timed acquire (see
+        // holdWakeLockBriefly) and an untimed one replace each other.
+        wakeLock.setReferenceCounted(false);
 
         // Get max available VM memory, exceeding this amount will throw an
         // OutOfMemory exception. Stored in kilobytes as LruCache takes an
@@ -353,6 +365,13 @@ public class AudioService extends MediaBrowserServiceCompat {
     }
 
     public void stop() {
+        // WoolyTube: stopSelf() alone does not end the service while the app's
+        // activity is still bound to it, and Android ignores cancel() for a
+        // foreground notification. Leave the foreground state here, so the
+        // notification goes away and the CPU may sleep.
+        ServiceCompat.stopForeground(this, STOP_FOREGROUND_REMOVE);
+        releaseWakeLock();
+        notificationCreated = false;
         deactivateMediaSession();
         stopSelf();
     }
@@ -372,7 +391,9 @@ public class AudioService extends MediaBrowserServiceCompat {
         artBitmapCache.evictAll();
         compactActionIndices = null;
         releaseMediaSession();
-        ServiceCompat.stopForeground(this, config.androidResumeOnClick ? STOP_FOREGROUND_DETACH : STOP_FOREGROUND_REMOVE);
+        // WoolyTube: always remove. A detached notification outlives the
+        // media session released above, so its buttons would do nothing.
+        ServiceCompat.stopForeground(this, STOP_FOREGROUND_REMOVE);
         // This still does not solve the Android 11 problem.
         // if (notificationCreated) {
         //     NotificationManager notificationManager = getNotificationManager();
@@ -703,11 +724,13 @@ public class AudioService extends MediaBrowserServiceCompat {
     }
 
     private void enterPlayingState() {
+        // WoolyTube: take the wake lock first, so playback keeps the CPU awake
+        // even if starting the foreground service throws.
+        acquireWakeLock();
         ContextCompat.startForegroundService(this, new Intent(AudioService.this, AudioService.class));
         if (!mediaSession.isActive())
             mediaSession.setActive(true);
 
-        acquireWakeLock();
         mediaSession.setSessionActivity(contentIntent);
         internalStartForeground();
     }
@@ -715,6 +738,11 @@ public class AudioService extends MediaBrowserServiceCompat {
     private void exitPlayingState() {
         if (config.androidStopForegroundOnPause) {
             exitForegroundState();
+        } else {
+            // WoolyTube: stay in the foreground while paused, so resuming from
+            // the notification or the background needs no new foreground
+            // start, but let the CPU sleep after a short grace period.
+            holdWakeLockBriefly();
         }
     }
 
@@ -729,8 +757,17 @@ public class AudioService extends MediaBrowserServiceCompat {
     }
 
     private void acquireWakeLock() {
-        if (!wakeLock.isHeld())
-            wakeLock.acquire();
+        // WoolyTube: acquire even when held, which cancels a timed release.
+        wakeLock.acquire();
+    }
+
+    // WoolyTube: keeps the CPU awake for IDLE_WAKE_LOCK_MS while nothing
+    // plays, so a pause between songs or a media button pressed while paused
+    // (for example a headset click with the screen off) is handled before the
+    // phone sleeps. Playing takes an untimed lock instead.
+    private void holdWakeLockBriefly() {
+        if (playing || wakeLock == null) return;
+        wakeLock.acquire(IDLE_WAKE_LOCK_MS);
     }
 
     private void releaseWakeLock() {
@@ -919,12 +956,14 @@ public class AudioService extends MediaBrowserServiceCompat {
         @Override
         public void onPlay() {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onPlay();
         }
 
         @Override
         public void onPlayFromMediaId(final String mediaId, final Bundle extras) {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onPlayFromMediaId(mediaId, extras);
         }
 
@@ -943,6 +982,7 @@ public class AudioService extends MediaBrowserServiceCompat {
         @Override
         public boolean onMediaButtonEvent(Intent mediaButtonEvent) {
             if (listener == null) return false;
+            holdWakeLockBriefly(); // WoolyTube
             // TODO: use typesafe version once SDK 33 is released.
             @SuppressWarnings("deprecation")
             final KeyEvent event = (KeyEvent)mediaButtonEvent.getExtras().getParcelable(Intent.EXTRA_KEY_EVENT);
```
