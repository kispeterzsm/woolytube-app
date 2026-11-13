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
6. `onPlay`, `onPlayFromMediaId`, `onMediaButtonEvent` and the other transport controls (`onSkipToNext`, `onSkipToPrevious`, `onSkipToQueueItem`, `onSeekTo`, `onFastForward`, `onRewind`, `onCustomAction`) hold the CPU awake for 10 s when nothing is playing, so a button pressed while paused (for example a headset click with the screen off, which waits for a possible double click, or Next on Android Auto or the lock screen) is handled before the phone sleeps. Playing then takes the untimed lock.
7. `enterPlayingState()` takes the wake lock before `startForegroundService`, so playback keeps the CPU awake even if that call throws.

The app's handler (`lib/services/audio_handler.dart`) also overrides `onNotificationDeleted`, whose default would stop playback and forget the saved session. Android marks the foreground notification as not dismissible, so this is rare. Where a phone does let the user swipe the paused notification away, the service and the app's engine stay in the foreground without a visible notification until the next play or pause shows it again. That keeps some memory in use, but nothing breaks and the saved session is kept.

## How to test on the phone

The native changes are not covered by `flutter test`, so check them on the phone after installing a build with this copy. Run these read-only commands from the computer while testing:

```
# 1. Is the notification there? (no output = gone)
adb shell dumpsys notification --noredact | grep -A3 'pkg=com.woolytube.woolytube id=1124'
# 2. Is the media service in the foreground?
adb shell dumpsys activity services com.woolytube.woolytube | grep -E 'AudioService|isForeground'
# 3. Does the plugin hold the CPU awake? (no output = released)
adb shell dumpsys power | grep -i 'com.ryanheise.audioservice'
# Optional: follow what happens
adb logcat -v time | grep -iE 'audioservice|MediaSessionService.*woolytube|ForegroundService'
```

"Gone" below means: command 1 prints nothing, command 2 shows `isForeground=false` (or no `AudioService` record at all), and command 3 prints nothing. Wait about 1 s after the action before checking.

1. **Stop by swiping the mini player away (the original bug).** Play a song, swipe the mini player away, press Home. The notification is gone. Before the fix it stayed with "Play" and its buttons did nothing.
2. **Stop by deleting.** Play a song and delete it from the app. Do it again with a playing song's playlist. Each time the notification is gone, and nothing keeps playing.
3. **Play again after a stop.** After step 1 or 2, start a song from the app. The notification comes back with the right title and buttons, command 2 shows `isForeground=true`, and command 3 lists the wake lock while it plays.
4. **Pause stays, and the CPU may sleep.** Play, press Home, pause from the notification. The notification stays (no time limit), and command 2 still shows `isForeground=true`. After more than 10 s, command 3 prints nothing. Turn the screen off for a minute or more, then resume in turn from the notification, the lock screen and a headset button (single click; also try a double click for Next). Each resumes at once, and command 3 lists the wake lock again while playing.
5. **Paused, then swiped from Recents.** Play, pause, swipe WoolyTube away in Recents. The notification stays. Wait more than 10 s with the screen off, then press Play and Next on the notification: both work, and the paused song continues from where it was. Also check that a playing song keeps playing after a Recents swipe.
6. **Song changes with the screen off.** Play a playlist, turn the screen off, and let at least two songs end on their own (also a song that has to load slowly, if there is one). The next song starts every time. This checks that the 10 s grace between songs is enough.
7. **Audio focus.** Play, press Home, take a phone call (or start something that briefly takes the audio, such as a voice message or navigation prompt), and end it. Playback resumes as before. This is the case commit `1485430` protects, and the service stays in the foreground while paused, so it should still work.
8. **Resume where I left off.** Pause a song in the middle and close the app from Recents. If Android lets you swipe the paused notification away, do that too. Open the app again: the same song is shown paused at the same position. Only the stop in step 1 or a delete in step 2 forgets it, as before.
9. **No orphan at startup.** Close the app with nothing playing (after step 1), then open it again. Command 1 prints nothing while nothing plays.

If something fails, save the output of the three commands and `adb logcat -d -v time > log.txt` right after it happens.

## Updating

Copy the new upstream package over this folder, but leave out `example/`, `test/`, `analysis_options.yaml` and upstream's `README.md`: this README holds the list of changes and the exact diff below, which are needed to re-apply them. Then re-apply the changes above and update the diff (`git diff --relative=plugins/audio_service/ <vendor commit> -- plugins/audio_service/android`). Check upstream's CHANGELOG first: if it fixes `stop()` leaving the foreground, some of them may no longer be needed.

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
@@ -1014,36 +1054,42 @@ public class AudioService extends MediaBrowserServiceCompat {
         @Override
         public void onSkipToNext() {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onSkipToNext();
         }
 
         @Override
         public void onSkipToPrevious() {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onSkipToPrevious();
         }
 
         @Override
         public void onFastForward() {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onFastForward();
         }
 
         @Override
         public void onRewind() {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onRewind();
         }
 
         @Override
         public void onSkipToQueueItem(long id) {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onSkipToQueueItem(id);
         }
 
         @Override
         public void onSeekTo(long pos) {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             listener.onSeekTo(pos);
         }
 
@@ -1080,6 +1126,7 @@ public class AudioService extends MediaBrowserServiceCompat {
         @Override
         public void onCustomAction(String action, Bundle extras) {
             if (listener == null) return;
+            holdWakeLockBriefly(); // WoolyTube
             if (CUSTOM_ACTION_STOP.equals(action)) {
                 listener.onStop();
             } else if (CUSTOM_ACTION_FAST_FORWARD.equals(action)) {
```
