package com.xiongjian.reader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * 阅读器的系统文件入口。
 *
 * 使用系统 SAF 选择器，无需申请整个存储空间权限。选中的文件在工作线程复制到
 * 缓存，Flutter 只处理本应用可访问的普通文件；所有通道回调均回到主线程。
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var selectingFont = false
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var destroyed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.xiongjian.reader/platform").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportPath" -> result.success(filesDir.absolutePath)
                    "readingMode" -> result.success(null)
                    "pick" -> {
                        if (pendingResult != null) {
                            result.error("busy", "文件选择器已打开", null)
                        } else {
                            pendingResult = result
                            try {
                                selectingFont = call.argument<Boolean>("font") == true
                                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "*/*"
                                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                                }
                                @Suppress("DEPRECATION")
                                startActivityForResult(intent, PICK_REQUEST)
                            } catch (error: Exception) {
                                pendingResult = null
                                result.error("picker", "无法打开系统文件选择器", null)
                            }
                        }
                    }
                    "discard" -> {
                        val paths = call.arguments as? List<*>
                        val cacheRoot = cacheDir.canonicalPath + File.separator
                        worker.execute {
                            paths?.filterIsInstance<String>()?.forEach { path ->
                                runCatching {
                                    val file = File(path)
                                    if (file.canonicalPath.startsWith(cacheRoot)) file.delete()
                                }
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 文件复制放到串行执行器；仅电子书限制大小，字体使用固定缓冲区，并响应销毁中断。 */
    @Deprecated("系统兼容回调", ReplaceWith("super.onActivityResult(requestCode, resultCode, data)"))
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val result = pendingResult ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult = null
            result.success(emptyList<String>())
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (index in 0 until minOf(clip.itemCount, 500)) {
                clip.getItemAt(index)?.uri?.let { uris.add(it) }
            }
        } else data.data?.let { uris.add(it) }
        val font = selectingFont
        selectingFont = false
        val resolver = contentResolver
        val cache = cacheDir
        worker.execute {
            val copied = mutableListOf<String>()
            try {
                for (uri in uris) {
                    if (Thread.currentThread().isInterrupted) throw InterruptedException()
                    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                        null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: "book.txt"
                    val safeName = name.substringAfterLast('/').substringAfterLast('\\')
                        .replace(Regex("[^\\p{L}\\p{N}._ ()-]"), "_").takeLast(160)
                    val target = File(cache, "${UUID.randomUUID()}_$safeName")
                    copied.add(target.absolutePath)
                    resolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(65536)
                            var total = 0L
                            while (true) {
                                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                if (!font && total > MAX_BYTES) throw IllegalArgumentException("文件超过 64 MB")
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: throw IllegalArgumentException("无法读取所选文件")
                }
                mainHandler.post {
                    if (!destroyed && pendingResult === result) {
                        pendingResult = null
                        result.success(copied)
                    } else copied.forEach { File(it).delete() }
                }
            } catch (error: Exception) {
                copied.forEach { File(it).delete() }
                mainHandler.post {
                    if (!destroyed && pendingResult === result) {
                        pendingResult = null
                        result.error("read", error.message ?: "读取文件失败", null)
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        destroyed = true
        channel?.setMethodCallHandler(null)
        channel = null
        pendingResult?.error("closed", "窗口已关闭", null)
        pendingResult = null
        worker.shutdownNow()
        super.onDestroy()
    }

    private companion object {
        const val PICK_REQUEST = 7301
        const val MAX_BYTES = 64L * 1024 * 1024
    }
}
