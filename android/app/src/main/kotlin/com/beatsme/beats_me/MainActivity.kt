package com.beatsme.beats_me

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Hosts the `beats_me/system` channel used by mixtape transfers: device
/// name, free space, the Wi-Fi multicast lock (needed to hear the PC's
/// discovery broadcast), the transfer foreground service, and files/links
/// handed to the app (Open with, Share, Quick Share, beatsme:// QR links,
/// USB import requests). It also keeps the screen on during playback.
class MainActivity : AudioServiceActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, String>? = null
    private var dartReady = false
    private var multicast: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "beats_me/system")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> result.success(deviceName())
                "freeBytes" -> result.success(freeBytes(call.argument<String>("path")))
                "multicastLock" -> {
                    setMulticast(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "startTransferService" -> {
                    val i = Intent(this, TransferService::class.java)
                        .putExtra("text", call.argument<String>("text") ?: "Ready to receive mixtapes")
                    try {
                        ContextCompat.startForegroundService(this, i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopTransferService" -> {
                    stopService(Intent(this, TransferService::class.java))
                    result.success(null)
                }
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on") == true
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                "takePendingIntent" -> {
                    dartReady = true
                    result.success(pending)
                    pending = null
                }
                else -> result.notImplemented()
            }
        }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onDestroy() {
        setMulticast(false)
        super.onDestroy()
    }

    private fun deliver(m: Map<String, String>) {
        runOnUiThread {
            val ch = channel
            if (ch == null || !dartReady) {
                pending = m
            } else {
                ch.invokeMethod("onIntent", m)
            }
        }
    }

    private fun handle(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (intent.getBooleanExtra("beatsme_handled", false)) return
        intent.putExtra("beatsme_handled", true)
        when (action) {
            "com.beatsme.IMPORT_INBOX" -> deliver(mapOf("type" to "inbox"))
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return
                if (data.scheme == "beatsme") {
                    deliver(mapOf("type" to "link", "value" to data.toString()))
                } else {
                    copyIn(data)
                }
            }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
                if (uri != null) {
                    copyIn(uri)
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (text != null && text.startsWith("beatsme://")) {
                        deliver(mapOf("type" to "link", "value" to text.trim()))
                    }
                }
            }
        }
    }

    /// Copies a shared/opened file into the cache so Dart can read it.
    private fun copyIn(uri: Uri) {
        deliver(mapOf("type" to "receiving", "value" to (displayName(uri) ?: "file")))
        Thread {
            try {
                val name = (displayName(uri) ?: "incoming.beatsmix").replace(Regex("[/\\\\]"), "_")
                val dir = File(cacheDir, "incoming").apply { mkdirs() }
                dir.listFiles()?.forEach { it.delete() }
                val out = File(dir, name)
                val input = if (uri.scheme == "file") {
                    File(uri.path!!).inputStream()
                } else {
                    contentResolver.openInputStream(uri) ?: throw IllegalStateException("cannot open")
                }
                input.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 16) } }
                deliver(mapOf("type" to "file", "value" to out.absolutePath))
            } catch (e: Exception) {
                deliver(mapOf("type" to "error", "value" to "Couldn't open the file: ${e.message}"))
            }
        }.start()
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun deviceName(): String {
        val n = try {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        } catch (e: Exception) {
            null
        }
        return if (n.isNullOrBlank()) Build.MODEL else n
    }

    private fun freeBytes(path: String?): Long = try {
        val target = path?.let { File(it) }?.takeIf { it.exists() } ?: Environment.getExternalStorageDirectory()
        StatFs(target.path).availableBytes
    } catch (e: Exception) {
        -1L
    }

    private fun setMulticast(on: Boolean) {
        if (on) {
            if (multicast?.isHeld == true) return
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("beats-me-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else {
            try {
                multicast?.release()
            } catch (e: Exception) {
            }
            multicast = null
        }
    }
}
