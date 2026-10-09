package com.nasmusic.nasmusic

import android.content.ClipData
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.provider.Settings
import android.util.Log
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
        private const val SHARE_TAG = "NASMusicShare"
    }

    // Deep links (open.spotify.com / music.youtube.com / youtu.be) arrive
    // either in onCreate (cold start) or onNewIntent (warm). The URL is kept
    // so the app can pull it on first boot ("getInitialLink") or be pushed it
    // immediately ("openUrl") when it's already running.
    // WhatsApp shares arrive TWO ways: tapping a chat URL = VIEW with
    // tracking query (?si=…&utm_source=… — our filters carry NO pathPattern
    // so any path+query still matches); "share to app" = ACTION_SEND
    // text/plain with the link inside EXTRA_TEXT (intent.data is null there).
    private var pendingUrl: String? = null
    private var messenger: BinaryMessenger? = null

    private fun extractLink(intent: Intent?): String? {
        if (intent == null) return null
        intent.data?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        if (intent.action == Intent.ACTION_SEND) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                .orEmpty() + "\n" + intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString().orEmpty()
            Regex("""https?://\S+""").find(text)?.value
                ?.trimEnd(')', ']', '.', ',', ';', '!')
                ?.takeIf { it.isNotBlank() }?.let { return it }
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Capture the cold-start intent data up front — configureFlutterEngine
        // runs INSIDE super.onCreate, i.e. BEFORE our onCreate body stores it,
        // so grabbing it here (plus the eager flush below) removes any race in
        // which a deep link is orphaned between activity start and first frame.
        extractLink(intent)?.let { pendingUrl = it }
        super.configureFlutterEngine(flutterEngine)
        messenger = flutterEngine.dartExecutor.binaryMessenger
        audioEventChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nasmusic.nasmusic/audio_events",
        )
        MethodChannel(messenger!!, "com.nasmusic.nasmusic/share")
            .setMethodCallHandler { call, result ->
                // Every tier logs its entry + outcome: the 1.0.268 IG tap
                // left ZERO logcat output, so a dead tap was indistinguishable
                // from a working one. Logcat now shows the full chain.
                Log.i(SHARE_TAG, "call ${call.method}")
                if (call.method == "shareText") {
                    val text = call.argument<String>("text").orEmpty()
                    val subject = call.argument<String>("subject").orEmpty()
                    val ok = shareText(text, subject)
                    Log.i(SHARE_TAG, "result shareText ok=$ok")
                    result.success(ok)
                } else if (call.method == "shareStory") {
                    val link = call.argument<String>("link").orEmpty()
                    val r = shareStoryToInstagram(link)
                    Log.i(SHARE_TAG, "result shareStory $r")
                    result.success(r)
                } else if (call.method == "shareDirectInstagram") {
                    val text = call.argument<String>("text").orEmpty()
                    val r = shareDirectToInstagram(text)
                    Log.i(SHARE_TAG, "result shareDirectInstagram $r")
                    result.success(r)
                } else if (call.method == "shareInstagramFallback") {
                    val text = call.argument<String>("text").orEmpty()
                    val r = shareInstagramFallback(text)
                    Log.i(SHARE_TAG, "result shareInstagramFallback $r")
                    result.success(r)
                } else if (call.method == "copyLinkOpenInstagram") {
                    val link = call.argument<String>("link").orEmpty()
                    val text = call.argument<String>("text").orEmpty()
                    val r = copyLinkOpenInstagram(link, text)
                    Log.i(SHARE_TAG, "result copyLinkOpenInstagram $r")
                    result.success(r)
                } else if (call.method == "saveCoverCopyCaption") {
                    val text = call.argument<String>("text").orEmpty()
                    val r = saveCoverCopyCaption(text)
                    Log.i(SHARE_TAG, "result saveCoverCopyCaption $r")
                    result.success(r)
                } else if (call.method == "canShareToInstagram") {
                    val ok = canShareToInstagram()
                    Log.i(SHARE_TAG, "result canShareToInstagram ok=$ok")
                    result.success(ok)
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
        // Cold start goes ONLY via getInitialLink (Dart pulls it post-frame
        // when the navigator exists). Forwarding here too would deliver the
        // same URL twice (openUrl event + getInitialLink) → double
        // NowPlaying push + double playOne race.
        registerNoisyReceiver()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        extractLink(intent)?.let { pendingUrl = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractLink(intent)?.let {
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

    // Instagram Stories share: MINIMAL known-good ADD_TO_STORY — a single
    // background image asset URI + source_application + grant flags. The
    // sticker asset (interactive_asset_uri), content_url attribution and
    // background colors are deliberately DROPPED: taps launched fine ('ok')
    // but Instagram opened-then-closed = content rejected inside IG, and the
    // sticker extra is the prime reject suspect. Returns 'ok' or
    // 'fail: <reason> artExists=.. artSize=.. authority=.. err=..'
    // so one User-errors row reveals the cause. False-equivalent = not
    // installed / no art on disk / launch failed → Dart falls back to the
    // generic sheet + clipboard. A user cancel inside Instagram returns
    // nothing (fire-and-forget composer) and needs no handling.
    // Authority MUST match the manifest provider
    // (com.nasmusic.nasmusic.art) — verified, custom ArtFileProvider.
    //
    // LAUNCH-FIRST (no resolveActivity gate): package queries are blocked on
    // many ROMs (Morphe variants, work profiles), so resolveActivity()
    // returns null even when Instagram IS installed — gating on it produced
    // false "no-resolve" rows. Just startActivity each candidate package in
    // order and catch ActivityNotFoundException; the caught exception text is
    // the diagnostic. resolveActivity survives only in canShareToInstagram
    // (chooser-row label).
    private fun shareStoryToInstagram(link: String): String {
        val authority = ArtFileProvider.AUTHORITY
        return try {
            // Preflight BEFORE firing the intent: a missing OR zero-byte art
            // file makes Instagram open then immediately close (flash) — fall
            // back to the generic sheet without launching anything.
            val file = java.io.File(getExternalFilesDir(null), ArtFileProvider.ART_FILE_NAME)
            val exists = file.exists()
            val size = if (exists) file.length() else -1L
            val readable = if (exists) file.canRead() else false
            if (!exists || !readable || size <= 0L) {
                return "fail: no-art artExists=$exists artSize=$size readable=$readable authority=$authority"
            }
            val uri = ArtFileProvider.ART_URI
            val errs = mutableListOf<String>()
            for (pkg in storyPackages()) {
                val story = Intent("com.instagram.share.ADD_TO_STORY").apply {
                    setDataAndType(uri, "image/jpeg")
                    putExtra("source_application", packageName)
                    clipData = ClipData.newUri(contentResolver, "story", uri)
                    setPackage(pkg)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                grantUriPermission(
                    pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                try {
                    startActivity(story)
                    return "ok"
                } catch (e: Exception) {
                    errs.add("$pkg: $e")
                }
            }
            "fail: launch-failed artExists=$exists artSize=$size authority=$authority err=${errs.joinToString(" | ")}"
        } catch (e: Exception) {
            "fail: exception=${e} authority=$authority"
        }
    }

    // Stories-capable packages: the two known ones first, then ANY other app
    // claiming the Stories action (Morphe/modded clients use their own
    // package names but the same action). Query needs the ADD_TO_STORY
    // <queries> intent in the manifest; an empty result just means the two
    // known packages are tried alone.
    private fun knownIgPackages() =
        listOf("com.instagram.android", "com.instagram.lite")

    private fun queriedStoryPackages(): List<String> = runCatching {
        packageManager.queryIntentActivities(
            Intent("com.instagram.share.ADD_TO_STORY"), 0,
        ).mapNotNull { it.activityInfo?.packageName }.distinct()
    }.getOrDefault(emptyList())

    // ANY share handler whose package looks like instagram.* (Morphe/modded
    // clients use their own package names): query generic SEND handlers and
    // keep the instagram ones. Needs the SEND/text/plain <queries> intent;
    // an empty result just means the known packages are tried alone.
    private fun queriedSendPackages(): List<String> = runCatching {
        packageManager.queryIntentActivities(
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, "https://www.instagram.com/")
            }, 0,
        ).mapNotNull { it.activityInfo?.packageName }
            .filter { it.contains("instagram", ignoreCase = true) }
            .distinct()
    }.getOrDefault(emptyList())

    private fun storyPackages(): List<String> =
        (knownIgPackages() + queriedStoryPackages() + queriedSendPackages()).distinct()

    // Launch-candidate packages for direct/fallback tiers: same universe.
    private fun igPackages(): List<String> = storyPackages()

    // Share-time gate for the IG chooser row: true when Instagram can
    // actually handle a share (Stories composer OR a direct SEND to the
    // full/Lite package OR any queried Stories handler). Lets Dart label the
    // row instead of falling through to the generic sheet silently.
    // LABEL ONLY — the share paths above launch-first and never consult this,
    // and Dart always attempts the tiers even when this says false (package
    // queries can be blocked while startActivity still works).
    private fun canShareToInstagram(): Boolean {
        val story = Intent("com.instagram.share.ADD_TO_STORY").apply {
            setPackage("com.instagram.android")
        }
        if (packageManager.resolveActivity(story, 0) != null) return true
        if (queriedStoryPackages().isNotEmpty()) return true
        if (queriedSendPackages().isNotEmpty()) return true
        return knownIgPackages().any { pkg ->
            packageManager.resolveActivity(
                Intent(Intent.ACTION_SEND).apply { setPackage(pkg) }, 0,
            ) != null
        }
    }

    // Middle tier: direct IG content share (artwork + caption) pinned to the
    // Instagram package so IG itself opens — never the generic sheet (where
    // the user could pick WhatsApp). Tries full then Lite, then any other
    // Stories-capable package. Same art preflight as Stories:
    // missing/unreadable/zero-byte art → fail string without launching.
    // LAUNCH-FIRST like Stories: no resolveActivity gate, catch the actual
    // launch exception per package.
    private fun shareDirectToInstagram(text: String): String {
        val authority = ArtFileProvider.AUTHORITY
        return try {
            val file = java.io.File(getExternalFilesDir(null), ArtFileProvider.ART_FILE_NAME)
            val exists = file.exists()
            val size = if (exists) file.length() else -1L
            val readable = if (exists) file.canRead() else false
            if (!exists || !readable || size <= 0L) {
                return "fail: no-art artExists=$exists artSize=$size readable=$readable authority=$authority"
            }
            val uri = ArtFileProvider.ART_URI
            val pkgs = igPackages()
            if (pkgs.isEmpty()) {
                return "fail: no-resolve artExists=$exists artSize=$size authority=$authority err=no IG package found"
            }
            val errs = mutableListOf<String>()
            for (pkg in pkgs) {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "image/jpeg"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    if (text.isNotBlank()) putExtra(Intent.EXTRA_TEXT, text)
                    clipData = ClipData.newUri(contentResolver, "share", uri)
                    setPackage(pkg)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try {
                    startActivity(send)
                    return "ok"
                } catch (e: Exception) {
                    errs.add("$pkg: $e")
                }
            }
            "fail: launch-failed artExists=$exists artSize=$size authority=$authority err=${errs.joinToString(" | ")}"
        } catch (e: Exception) {
            "fail: exception=$e authority=$authority"
        }
    }

    // Final tier: save cover to gallery + copy caption + launch Instagram
    // itself. No fragile Stories/direct API — the user pastes inside IG.
    // Returns 'ok' or 'fail: <reason>'.
    private fun shareInstagramFallback(caption: String): String {
        val authority = ArtFileProvider.AUTHORITY
        return try {
            val file = java.io.File(getExternalFilesDir(null), ArtFileProvider.ART_FILE_NAME)
            val exists = file.exists()
            val size = if (exists) file.length() else -1L
            if (!exists || size <= 0L) {
                return "fail: no-art artExists=$exists artSize=$size authority=$authority"
            }
            // 1. Gallery: MediaStore insert (Q+) so the cover is pickable in IG.
            runCatching {
                if (Build.VERSION.SDK_INT >= 29) {
                    val values = android.content.ContentValues().apply {
                        put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "nasmusic_cover_${System.currentTimeMillis()}.jpg")
                        put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/NASMusic")
                    }
                    val uri = contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    if (uri != null) contentResolver.openOutputStream(uri)?.use { out ->
                        file.inputStream().use { it.copyTo(out) }
                    }
                } else {
                    val pics = android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_PICTURES)
                    val out = java.io.File(pics, "nasmusic_cover_${System.currentTimeMillis()}.jpg")
                    file.copyTo(out, overwrite = true)
                    sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(out)))
                }
            }
            // 2. Caption to clipboard.
            runCatching {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText("caption", caption))
            }
            // 3. Launch Instagram itself.
            val pkgs = igPackages()
            val ordered = (listOf("com.instagram.android", "com.instagram.lite") + pkgs).distinct()
            val errs = mutableListOf<String>()
            for (pkg in ordered) {
                val launch = packageManager.getLaunchIntentForPackage(pkg) ?: continue
                try {
                    startActivity(launch)
                    return "ok"
                } catch (e: Exception) {
                    errs.add("$pkg: $e")
                }
            }
            "fail: launch-failed artExists=$exists artSize=$size authority=$authority err=${errs.joinToString(" | ").ifEmpty { "no IG package found" }}"
        } catch (e: Exception) {
            "fail: exception=$e authority=$authority"
        }
    }

    // No-launch tier: gallery save + clipboard only (unresolvable Stories/
    // direct targets — launching just flashes IG open/closed on Morphe builds).
    private fun saveCoverCopyCaption(caption: String): String {
        val authority = ArtFileProvider.AUTHORITY
        return try {
            val file = java.io.File(getExternalFilesDir(null), ArtFileProvider.ART_FILE_NAME)
            val exists = file.exists()
            val size = if (exists) file.length() else -1L
            if (!exists || size <= 0L) {
                return "fail: no-art artExists=$exists artSize=$size authority=$authority"
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= 29) {
                    val values = android.content.ContentValues().apply {
                        put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "nasmusic_cover_${System.currentTimeMillis()}.jpg")
                        put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/NASMusic")
                    }
                    val uri = contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    if (uri != null) contentResolver.openOutputStream(uri)?.use { out ->
                        file.inputStream().use { it.copyTo(out) }
                    }
                } else {
                    val pics = android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_PICTURES)
                    val out = java.io.File(pics, "nasmusic_cover_${System.currentTimeMillis()}.jpg")
                    file.copyTo(out, overwrite = true)
                    sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(out)))
                }
            }
            runCatching {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText("caption", caption))
            }
            "ok"
        } catch (e: Exception) {
            "fail: exception=$e authority=$authority"
        }
    }

    // Always-works tier: copy the link + open Instagram itself. Needs NO
    // artwork (survives Morphe builds that reject the art intents, and no
    // cover on disk). Tries a launch intent per instagram.* package, then a
    // plain VIEW of instagram.com (any browser handles it). Returns 'ok' or
    // 'fail: <reason>' — the Dart side falls back to the generic sheet.
    private fun copyLinkOpenInstagram(link: String, caption: String): String {
        return try {
            val text = if (link.isNotBlank()) link else caption
            if (text.isBlank()) return "fail: empty-link"
            runCatching {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText("link", text))
            }
            val errs = mutableListOf<String>()
            for (pkg in (listOf("com.instagram.android", "com.instagram.lite") + igPackages()).distinct()) {
                val launch = packageManager.getLaunchIntentForPackage(pkg) ?: continue
                try {
                    startActivity(launch)
                    return "ok"
                } catch (e: Exception) {
                    errs.add("$pkg: $e")
                }
            }
            // No launchable IG package: VIEW instagram.com (browser always
            // resolves this — the link is already on the clipboard).
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.instagram.com/")))
                return "ok"
            } catch (e: Exception) {
                errs.add("view: $e")
            }
            "fail: launch-failed err=${errs.joinToString(" | ").ifEmpty { "no IG package found" }}"
        } catch (e: Exception) {
            "fail: exception=$e"
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