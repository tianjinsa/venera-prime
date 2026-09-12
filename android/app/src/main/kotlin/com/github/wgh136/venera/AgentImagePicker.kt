package com.github.wgh136.venera

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

internal class AgentImagePickerContract : ActivityResultContract<Unit, List<Uri>>() {
    override fun createIntent(context: Context, input: Unit): Intent {
        if (ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(context)) {
            return ActivityResultContracts.PickMultipleVisualMedia().createIntent(
                context,
                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
            )
        }
        // AndroidX otherwise falls back to OPEN_DOCUMENT. GET_CONTENT with an
        // explicit chooser also offers installed galleries on older Android.
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(intent, "选择图片")
    }

    override fun parseResult(resultCode: Int, intent: Intent?): List<Uri> {
        return ActivityResultContracts.GetMultipleContents().parseResult(resultCode, intent)
    }
}

internal class AgentImagePickerException(val code: String, message: String) : IOException(message)

private const val AGENT_IMAGE_MAX_BYTES = 20 * 1024 * 1024

internal fun copyAgentImages(
    resolver: ContentResolver,
    cacheDir: File,
    uris: List<Uri>,
    isCancelled: () -> Boolean = { false }
): List<Map<String, String>> {
    val copies = mutableListOf<File>()
    fun checkCancelled() {
        if (isCancelled()) {
            throw AgentImagePickerException("IMAGE_PICK_CANCELLED", "图片选择已取消，请重新选择")
        }
    }
    try {
        val images = uris.distinct().mapIndexed { index, uri ->
            checkCancelled()
            var name = "图片${index + 1}"
            var reportedSize: Long? = null
            try {
                resolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null,
                    null,
                    null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameColumn >= 0) {
                            cursor.getString(nameColumn)?.takeIf { it.isNotBlank() }?.let { name = it }
                        }
                        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                            reportedSize = cursor.getLong(sizeColumn)
                        }
                    }
                }
            } catch (_: Exception) {
                // Metadata is optional for gallery providers; the stream below
                // still enforces the actual size limit and URI read access.
            }
            if (reportedSize != null && reportedSize!! > AGENT_IMAGE_MAX_BYTES) {
                throw AgentImagePickerException("IMAGE_TOO_LARGE", "图片“$name”超过20 MB，请缩小后添加")
            }
            checkCancelled()
            // Provider names are display-only; they never determine a path.
            val copy = File.createTempFile("agent_image_", ".tmp", cacheDir)
            copies.add(copy)
            checkCancelled()
            val input = resolver.openInputStream(uri)
                ?: throw IOException("无法打开图片“$name”")
            input.use { stream ->
                FileOutputStream(copy).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0
                    while (true) {
                        checkCancelled()
                        val count = stream.read(buffer)
                        if (count < 0) break
                        checkCancelled()
                        total += count
                        if (total > AGENT_IMAGE_MAX_BYTES) {
                            throw AgentImagePickerException(
                                "IMAGE_TOO_LARGE", "图片“$name”超过20 MB，请缩小后添加"
                            )
                        }
                        output.write(buffer, 0, count)
                    }
                }
            }
            mapOf("path" to copy.absolutePath, "name" to name)
        }
        checkCancelled()
        return images
    } catch (e: Exception) {
        // Include the partly copied current image and all earlier selections.
        copies.forEach { it.delete() }
        throw e
    }
}
