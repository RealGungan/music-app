package com.nasmusic.nasmusic

import android.content.ClipData
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.provider.Settings
import android.media.AudioManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    companion object {
        // The becoming-noisy receiver is process-lifetime: it is registered on
        // the APPLICATION context, NOT the Activity. While music plays in the
        // background (screen locked / in the car) Android destroys the Activity
        // but keeps the process alive via audio_service's foreground service —
        // an Activity-scoped receiver would be torn down with it, and
        // ACTION_AUDIO_BECOMING_NOISY (headphones/car-stereo disconnect) would
        // never reach Dart. A process-lifetime receiver survives that.
        @Volatile private var audioEventChannel: MethodChannel? = null
        @Volatile private var noisyReceiver: BroadcastReceiver? = null
    }

    // Deep links (open.spotify.com / music.youtube.com / youtu.be) arrive
    // either in onCreate (cold start) or onNewIntent (warm). The URL is kept
    // so the app can pull it on first boot ("getInitialLink") or be pushed it
    // immediately ("openUrl") when it's already running.
    private var pendingUrl: String? = null
    private var messenger: BinaryMessenger? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Capture the cold-start intent data up front — configureFlutterEngine
        // runs INSIDE super.onCreate, i.e. BEFORE our onCreate body stores it,
        // so grabbing it here (plus the eager flush below) removes any race in
        // which a deep link is orphaned between activity start and first frame.
        intent?.data?.toString()?.let { pendingUrl = it }
        super.configureFlutterEngine(flutterEngine)
        messenger = flutterEngine.dartExecutor.binaryMessenger
        audioEventChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nasmusic.nasmusic/audio_events",
        )
        MethodChannel(messenger!!, "com.nasmusic.nasmusic/share")
            .setMethodCallHandler { call, result ->
                if (call.method == "shareText") {
                    val text = call.argument<String>("text").orEmpty()
                    val subject = call.argument<String>("subject").orEmpty()
                    result.success(shareText(text, subject))
                } else if (call.method == "shareStory") {
                    val link = call.argument<String>("link").orEmpty()
                    result.success(shareStoryToInstagram(link))
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(messenger!!, "com.nasmusic.nasmusic/deep_links")
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialLink") {
                    // Only consume a REAL pending link: if the query races ahead
                    // of onNewIntent/onCreate, nulling an already-null pendingUrl
                    // would swallow a link that arrives a moment later.
                    if (pendingUrl != null) {
                        result.success(pendingUrl)
                        pendingUrl = null
                    } else {
                        result.success(null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(messenger!!, "com.nasmusic.nasmusic/system")
            .setMethodCallHandler { call, result ->
                if (call.method == "openSupportedLinks") {
                    result.success(openSupportedLinks())
                } else {
                    result.notImplemented()
                }
            }
        // If a deep link arrived before the engine was configured, flush it now.
        pendingUrl?.let { forwardDeepLink(it) }
        registerNoisyReceiver()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.data?.toString()?.let { pendingUrl = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.toString()?.let {
            pendingUrl = it
            forwardDeepLink(it)
        }
    }

    private fun forwardDeepLink(url: String) {
        messenger?.let { m ->
            runCatching {
                MethodChannel(m, "com.nasmusic.nasmusic/deep_links")
                    .invokeMethod("openUrl", url)
            }
        }
    }

    // A native ACTION_SEND share sheet for the YT-Music link the app built.
    // Returns true when the sheet was actually shown.
    private fun shareText(text: String, subject: String): Boolean {
        return try {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                if (subject.isNotBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
            }
            val chooser = Intent.createChooser(send, "Share to YouTube Music")
            runCatching { startActivity(chooser) }.isSuccess
        } catch (_: Exception) {
            false
        }
    }

    // Instagram Stories share: the current track's art file (written by the
    // audio handler for the notification) as the sticker + the resolved
    // track link as the tappable attribution. False = not installed / no
    // art on disk / launch failed → Dart falls back to the generic sheet +
    // clipboard. A user cancel inside Instagram returns nothing
    // (fire-and-forget composer) and needs no handling.
    private fun shareStoryToInstagram(link: String): Boolean {
        return try {
            // Preflight BEFORE firing the intent: a missing OR zero-byte art
            // file makes Instagram open then immediately close (flash) — fall
            // back to the generic sheet without launching anything.
            val file = java.io.File(getExternalFilesDir(null), ArtFileProvider.ART_FILE_NAME)
            if (!file.exists() || !file.canRead() || file.length() <= 0L) return false
            // Resolve BEFORE granting: no grant when IG can't handle it.
            val probe = Intent("com.instagram.share.ADD_TO_STORY").apply {
                setPackage("com.instagram.android")
            }
            if (packageManager.resolveActivity(probe, 0) == null) return false
            val uri = ArtFileProvider.ART_URI
            val story = Intent("com.instagram.share.ADD_TO_STORY").apply {
                setDataAndType(uri, "image/jpeg")
                putExtra("source_application", packageName)
                putExtra("interactive_asset_uri", uri)
                if (link.isNotBlank()) putExtra("content_url", link)
                putExtra("top_background_color", "#191919")
                putExtra("bottom_background_color", "#191919")
                clipData = ClipData.newUri(contentResolver, "story", uri).apply {
                    addItem(ClipData.Item(uri))
                }
                setPackage("com.instagram.android")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            grantUriPermission(
                "com.instagram.android", uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            runCatching { startActivity(story) }.isSuccess
        } catch (_: Exception) {
            false
        }
    }

    // Opens the system "Open supported links" page for THIS app, where the
    // user can enable open.spotify.com / music.youtube.com / www.youtube.com /
    // youtu.be deep links to open gungan.fm by default (one-time "Always" is
    // set there for all hosts at once, or per-host after clicking a link).
    // Returns true when the settings page could be shown.
    private fun openSupportedLinks(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS,
                Uri.parse("package:$packageName"),
            )
            runCatching { startActivity(intent) }.isSuccess
        } catch (_: Exception) {
            false
        }
    }

    // ACTION_AUDIO_BECOMING_NOISY fires when the car stereo / BT headphones
    // disconnect. We register our OWN receiver (NOT audio_session's, which is
    // unregistered the moment audioplayers takes audio focus) so playback can
    // pause regardless of who holds focus.
    private fun registerNoisyReceiver() {
        if (noisyReceiver != null) return
        // Application context: the receiver must NOT be tied to the Activity
        // lifecycle. Android can destroy the Activity while music plays with
        // the screen locked (the foreground service keeps the process alive);
        // an Activity-scoped receiver would silently die and unplugging
        // headphones would never pause the music. An app-context receiver
        // lives as long as the process, which is what we want here.
        noisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    audioEventChannel?.invokeMethod("becomingNoisy", null)
                }
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.registerReceiver(
                applicationContext, noisyReceiver, filter, ContextCompat.RECEIVER_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            applicationContext.registerReceiver(noisyReceiver, filter)
        }
    }

    override fun onDestroy() {
        // NOTE: the becoming-noisy receiver is intentionally NOT unregistered
        // here — it is registered on the application context and must outlive
        // the Activity (see registerNoisyReceiver). Unregistering it on
        // Activity destroy is what used to break headphone-unplug-pauses-music
        // when playback continued in the background.
        super.onDestroy()
    }
}