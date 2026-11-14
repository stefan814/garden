package io.github.stefan814.garden

import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CancellationException

/**
 * Resumable download of one pinned file, trying its urls in turn. The destination is abstract so the same code
 * fills a shared-store session or a private .part file. Hash checking is the caller's job (the system does it for
 * shared files at commit).
 */
internal class Http(private val retryDelayMs: Long = 2_000, private val attempts: Int = 6) {

    /**
     * @param have bytes already in the destination (resume point).
     * @param open opens the destination for writing at an offset; `restart` = the server ignored Range, so it's 0.
     */
    fun fetch(
        f: ModelFile,
        have: () -> Long,
        isCancelled: () -> Boolean,
        onBytes: (Long) -> Unit,
        open: (offset: Long, restart: Boolean) -> OutputStream,
    ) {
        var attempt = 0
        while (true) {
            if (isCancelled()) throw CancellationException("download of ${f.name} cancelled")
            val url = f.urls[attempt % f.urls.size]
            try {
                if (once(f, url, have(), isCancelled, onBytes, open)) return
                throw IOException("connection closed early")
            } catch (e: IOException) {
                if (++attempt >= attempts) throw GardenException.Download(f.name, e)
                Log.w(Garden.TAG, "${f.name}: ${e.message}; retry $attempt from ${have()} bytes")
                Thread.sleep(retryDelayMs * (1L shl (attempt - 1).coerceAtMost(5)))
            }
        }
    }

    /** One request. True when the destination holds all [ModelFile.size] bytes. */
    private fun once(
        f: ModelFile, url: String, start: Long, isCancelled: () -> Boolean, onBytes: (Long) -> Unit,
        open: (Long, Boolean) -> OutputStream,
    ): Boolean {
        var have = start.coerceAtMost(f.size)
        if (have == f.size) { onBytes(have); return true }
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000; readTimeout = 30_000; instanceFollowRedirects = true
            setRequestProperty("User-Agent", "Garden-Android")
            if (have > 0) setRequestProperty("Range", "bytes=$have-")
        }
        try {
            val out = when (val code = c.responseCode) {
                206 -> open(have, false)
                200 -> { val restart = have > 0; have = 0; open(0, restart) }
                416 -> return have == f.size
                else -> throw IOException("HTTP $code")
            }
            onBytes(have)
            out.use { o ->
                c.inputStream.use { inp ->
                    val buf = ByteArray(1 shl 16); var last = have
                    while (true) {
                        if (isCancelled()) throw CancellationException("download of ${f.name} cancelled")
                        val n = inp.read(buf); if (n < 0) break
                        if (have + n > f.size) throw IOException("server sent more than ${f.size} bytes")
                        o.write(buf, 0, n); have += n
                        if (have - last >= 1_000_000) { onBytes(have); last = have }
                    }
                }
            }
            onBytes(have)
            return have == f.size
        } finally { c.disconnect() }
    }
}
