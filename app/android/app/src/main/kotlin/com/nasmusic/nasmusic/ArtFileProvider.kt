package com.nasmusic.nasmusic

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Exported content provider that serves the album-art cache file to SystemUI
 * via a `content://` URI.
 *
 * On Android 13+/14, SystemUI's MediaDataManager resolves the media notification
 * artwork either from the metadata Bitmap or from a loadable URI (in the order
 * ART -> ALBUM_ART -> ALBUM_ART_URI -> ART_URI -> DISPLAY_ICON_URI). Neither an
 * app-private file path nor the (correctly) non-exported androidx FileProvider is
 * openable by SystemUI — both yield a gray "big square" placeholder. This provider
 * is exported (a plain ContentProvider CAN be exported, unlike androidx
 * FileProvider which throws "Provider must not be exported"), so SystemUI can open
 * the art directly through it.
 */
class ArtFileProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = File(context?.getExternalFilesDir(null), ART_FILE_NAME)
        // Zero-byte art reads as a broken sticker (IG open-close flash) —
        // fail here so the preflight + fallback path handles it instead.
        if (!file.exists() || !file.canRead() || file.length() <= 0L) {
            throw FileNotFoundException("Art file not ready: ${file.absolutePath}")
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String = "image/*"

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0

    companion object {
        const val ART_FILE_NAME = "nasmusic_art.jpg"
        const val AUTHORITY = "com.nasmusic.nasmusic.art"
        val ART_URI: Uri = Uri.parse("content://$AUTHORITY/$ART_FILE_NAME")
    }
}
