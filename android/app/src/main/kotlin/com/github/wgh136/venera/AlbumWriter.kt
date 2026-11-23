package com.github.wgh136.venera

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import java.io.File
import java.io.IOException

internal object AlbumWriter {
    fun save(
        context: Context,
        source: File,
        filename: String,
        mimeType: String,
        onResult: (Boolean) -> Unit
    ) {
        Thread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    publishImage(context, source, filename, mimeType)
                    onResult(true)
                } else {
                    saveLegacyImage(context, source, filename, mimeType, onResult)
                }
            } catch (_: Exception) {
                onResult(false)
            }
        }.start()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun publishImage(context: Context, source: File, filename: String, mimeType: String) {
        val resolver = context.contentResolver
        val metadata = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, filename)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, metadata)
            ?: throw IOException("Cannot create an album entry")
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IOException("Cannot open the album entry for writing")
            output.use { destination -> source.inputStream().use { it.copyTo(destination) } }
            val published = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            if (resolver.update(uri, published, null, null) != 1) {
                throw IOException("Cannot publish the album entry")
            }
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacyImage(
        context: Context,
        source: File,
        filename: String,
        mimeType: String,
        onResult: (Boolean) -> Unit
    ) {
        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
        directory.mkdirs()
        if (!directory.isDirectory) {
            throw IOException("Cannot open the public Pictures directory")
        }
        val name = filename.substringBeforeLast('.')
        val extension = filename.substringAfterLast('.')
        var destination = File(directory, filename)
        var suffix = 1
        while (!destination.createNewFile()) {
            destination = File(directory, "$name ($suffix).$extension")
            suffix++
        }
        try {
            source.inputStream().use { input ->
                destination.outputStream().use { output -> input.copyTo(output) }
            }
            MediaScannerConnection.scanFile(context, arrayOf(destination.path), arrayOf(mimeType)) { _, uri ->
                if (uri == null) destination.delete()
                onResult(uri != null)
            }
        } catch (error: Exception) {
            destination.delete()
            throw error
        }
    }
}
