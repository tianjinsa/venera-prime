package com.github.wgh136.venera

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import dev.flutter.packages.file_selector_android.FileUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    private val storageRequestCode = 0x10
    private var storagePermissionRequest: ((Boolean) -> Unit)? = null

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayList<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    private class AgentImagePickRequest(val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
    }

    private var nativeMethodChannel: MethodChannel? = null
    private var pendingAgentImagePick: AgentImagePickRequest? = null
    private var agentImagePickerOpen = false
    private val agentImageCopies = mutableSetOf<String>()
    // Consume restored results even when Activity recreation lost the request.
    private val agentImagePickerLauncher = registerForActivityResult(
        AgentImagePickerContract()
    ) { uris -> onPickedAgentImages(uris) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onDestroy() {
        cancelAgentImageRequests()
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cancelAgentImageRequests()
        nativeMethodChannel?.setMethodCallHandler(null)
        nativeMethodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            sharedTexts.add(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>
    ) {
        val key = "activity_rq_for_result#${nextLocalRequestCode.getAndIncrement()}"
        val registry = activityResultRegistry
        var launcher: ActivityResultLauncher<I>? = null
        val observer = object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (Lifecycle.Event.ON_DESTROY == event) {
                    launcher?.unregister()
                    lifecycle.removeObserver(this)
                }
            }
        }
        lifecycle.addObserver(observer)
        val newCallback = ActivityResultCallback<O> {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            callback.onActivityResult(it)
        }
        launcher = registry.register(key, contract, newCallback)
        launcher.launch(input)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/method_channel"
        )
        nativeMethodChannel = methodChannel
        methodChannel.setMethodCallHandler { call, res ->
            when (call.method) {
                "getProxy" -> res.success(getProxy())
                "pickAgentImages" -> pickAgentImages(res)
                "releaseAgentImages" -> {
                    releaseAgentImages(call.argument<List<String>>("paths") ?: emptyList())
                    res.success(null)
                }
                "setScreenOn" -> {
                    val set = call.argument<Boolean>("set") ?: false
                    if (set) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    res.success(null)
                }

                "getDirectoryPath" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
                        if (activityResult.resultCode != Activity.RESULT_OK) {
                            res.success(null)
                            return@startContractForResult
                        }
                        val pickedDirectoryUri = activityResult.data?.data
                        if (pickedDirectoryUri == null) {
                            res.success(null)
                            return@startContractForResult
                        }
                        onPickedDirectory(pickedDirectoryUri, res)
                    }
                }

                else -> res.notImplemented()
            }
        }

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.onUp = {
                        events.success(1)
                    }
                    volumeListen.onDown = {
                        events.success(2)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    listening = false
                }
            })

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/storage")
        storageChannel.setMethodCallHandler { _, res ->
            requestStoragePermission { result ->
                res.success(result)
            }
        }

        val selectFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/select_file")
        selectFileChannel.setMethodCallHandler { req, res ->
            val mimeType = req.arguments<String>()
            openFile(res, mimeType!!)
        }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = {text ->
                        events.success(text)
                    }
                    if (sharedTexts.isNotEmpty()) {
                        for (text in sharedTexts) {
                            events.success(text)
                        }
                        sharedTexts.clear()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    textShareHandler = null
                }
            })
    }

    private fun getProxy(): String {
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (host != null && port != null) {
            "$host:$port"
        } else {
            "No Proxy"
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (listening) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }

                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// Ensure that the directory is accessible by dart:io
    private fun onPickedDirectory(uri: Uri, result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            var plain = uri.toString()
            if(plain.contains("%3A")) {
                plain = Uri.decode(plain)
            }
            val externalStoragePrefix = "content://com.android.externalstorage.documents/tree/primary:";
            if(plain.startsWith(externalStoragePrefix)) {
                val path = plain.substring(externalStoragePrefix.length)
                result.success(Environment.getExternalStorageDirectory().absolutePath + "/" + path)
                return
            }
            // The uri cannot be parsed to plain path, use copy method
        }
        // dart:io cannot access the directory without permission.
        // so we need to copy the directory to cache directory
        val contentResolver = contentResolver
        // Do not use a provider-controlled directory name as a cache path.
        // A malformed provider can return an empty name or path separators.
        val tmp = File(
            cacheDir,
            "selected_directory_${nextLocalRequestCode.getAndIncrement()}"
        )
        if(tmp.exists()) {
            tmp.deleteRecursively()
        }
        if (!tmp.mkdirs()) {
            result.error("copy error", "Unable to create temporary directory", null)
            return
        }
        Thread {
            try {
                copyDirectory(contentResolver, uri, tmp)
                runOnUiThread { result.success(tmp.absolutePath) }
            }
            catch (e: Exception) {
                tmp.deleteRecursively()
                runOnUiThread { result.error("copy error", e.message, null) }
            }
        }.start()

    }

    private fun isSafeDocumentName(name: String?): Boolean {
        return !name.isNullOrBlank() && name != "." && name != ".." &&
            !name.contains('/') && !name.contains('\\')
    }

    private fun copyDirectory(resolver: ContentResolver, srcUri: Uri, destDir: File) {
        val src = DocumentFile.fromTreeUri(this, srcUri) ?: return
        for (file in src.listFiles()) {
            val fileName = file.name
            if (!isSafeDocumentName(fileName)) {
                throw IOException("Invalid document name")
            }
            val newFile = File(destDir, fileName!!)
            if (file.isDirectory) {
                val newDir = newFile
                if (!newDir.mkdirs() && !newDir.isDirectory) {
                    throw IOException("Unable to create directory")
                }
                copyDirectory(resolver, file.uri, newDir)
            } else {
                val input = resolver.openInputStream(file.uri)
                    ?: throw IOException("Unable to open document")
                input.use {
                    FileOutputStream(newFile).use { output ->
                        it.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            val writePermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            if (!readPermission || !writePermission) {
                storagePermissionRequest = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } else {
                result(true)
            }
        } else {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.addCategory("android.intent.category.DEFAULT")
                    intent.data = Uri.parse("package:$packageName")
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ _ ->
                        result(Environment.isExternalStorageManager())
                    }
                } catch (e: Exception) {
                    result(false)
                }
            } else {
                result(true)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            storagePermissionRequest?.invoke(grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            })
            storagePermissionRequest = null
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@startContractForResult
            }
            val contentResolver = contentResolver
            val file = DocumentFile.fromSingleUri(this, uri)
            if (file == null) {
                result.success(null)
                return@startContractForResult
            }
            val fileName = file.name
            if (fileName == null) {
                result.success(null)
                return@startContractForResult
            }
            if(hasStoragePermission()) {
                try {
                    val filePath = FileUtils.getPathFromUri(this, uri)
                    result.success(filePath)
                    return@startContractForResult
                }
                catch (e: Exception) {
                    // ignore
                }
            }
            // use copy method
            val tmp = File(cacheDir, fileName)
            if(tmp.exists()) {
                tmp.delete()
            }
            Log.i("Venera", "copy file (${fileName}) to ${tmp.absolutePath}")
            Thread {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tmp).use { output ->
                            input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                            output.flush()
                        }
                    }
                    result.success(tmp.absolutePath)
                }
                catch (e: Exception) {
                    result.error("copy error", e.message, null)
                }
            }.start()
        }
    }

    private fun pickAgentImages(result: MethodChannel.Result) {
        if (isFinishing || isDestroyed || nativeMethodChannel == null) {
            replyAgentImageError(result, "IMAGE_PICK_CANCELLED", "图片选择已取消，请重新选择")
            return
        }
        if (pendingAgentImagePick != null || agentImagePickerOpen) {
            replyAgentImageError(result, "IMAGE_PICK_IN_PROGRESS", "请先完成当前的图片选择")
            return
        }
        val request = AgentImagePickRequest(result)
        pendingAgentImagePick = request
        try {
            agentImagePickerOpen = true
            agentImagePickerLauncher.launch(Unit)
        } catch (e: Exception) {
            agentImagePickerOpen = false
            failAgentImagePick(request, "IMAGE_PICK_FAILED", "无法打开图片选择器：${e.message}")
        }
    }

    private fun onPickedAgentImages(uris: List<Uri>) {
        agentImagePickerOpen = false
        val request = pendingAgentImagePick ?: return
        if (uris.isEmpty()) {
            completeAgentImagePick(request, emptyList())
            return
        }
        val resolver = contentResolver
        val directory = cacheDir
        Thread {
            try {
                val images = copyAgentImages(resolver, directory, uris, request.cancelled::get)
                runOnUiThread { completeAgentImagePick(request, images) }
            } catch (e: AgentImagePickerException) {
                runOnUiThread { failAgentImagePick(request, e.code, e.message) }
            } catch (e: Exception) {
                runOnUiThread {
                    failAgentImagePick(request, "IMAGE_READ_FAILED", "无法读取所选图片：${e.message}")
                }
            }
        }.start()
    }

    private fun completeAgentImagePick(
        request: AgentImagePickRequest,
        images: List<Map<String, String>>
    ) {
        val paths = images.mapNotNull { it["path"] }
        // This callback may have been queued immediately before engine detach.
        // Track the copies first so either outcome removes every copied file.
        agentImageCopies.addAll(paths)
        if (pendingAgentImagePick !== request || request.cancelled.get()) {
            releaseAgentImages(paths)
            return
        }
        pendingAgentImagePick = null
        try {
            // Keep ownership until Dart finishes reading, including if the
            // engine disappears after this reply but before Dart's cleanup.
            request.result.success(images)
        } catch (e: Exception) {
            releaseAgentImages(paths)
            Log.w("Venera", "Unable to return selected images", e)
        }
    }

    private fun failAgentImagePick(request: AgentImagePickRequest, code: String, message: String?) {
        if (pendingAgentImagePick !== request || request.cancelled.get()) return
        pendingAgentImagePick = null
        replyAgentImageError(request.result, code, message)
    }

    private fun cancelAgentImageRequests() {
        val request = pendingAgentImagePick
        pendingAgentImagePick = null
        if (request != null) {
            request.cancelled.set(true)
            replyAgentImageError(request.result, "IMAGE_PICK_CANCELLED", "图片选择已取消，请重新选择")
        }
        releaseAgentImages(agentImageCopies.toList())
    }

    private fun releaseAgentImages(paths: List<String>) {
        for (path in paths) {
            // Only native-owned copies can be removed through this channel.
            if (!agentImageCopies.contains(path)) continue
            try {
                val copy = File(path)
                if (!copy.exists() || copy.delete()) agentImageCopies.remove(path)
            } catch (e: Exception) {
                Log.w("Venera", "Unable to remove a temporary selected image", e)
            }
        }
    }

    private fun replyAgentImageError(result: MethodChannel.Result, code: String, message: String?) {
        try {
            result.error(code, message, null)
        } catch (e: Exception) {
            // Cleanup still completes if a detached engine rejects the reply.
            Log.w("Venera", "Unable to return image picker failure", e)
        }
    }
}

class VolumeListen {
    var onUp = fun() {}
    var onDown = fun() {}
    fun up() {
        onUp()
    }

    fun down() {
        onDown()
    }
}
