package io.github.stefan814.garden

import android.app.blob.BlobHandle
import android.app.blob.BlobStoreManager
import android.content.Context
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.annotation.WorkerThread
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/** Where a ready model lives. */
enum class Where { SHARED, PRIVATE }

/** What an app can do with a model right now. Drives the "use shared / download" choice screen. */
sealed interface ModelState {
    /** This app holds the model and can [Garden.open] it. */
    data class Ready(val where: Where) : ModelState
    /** Another app put it in the shared store. [Garden.adopt] makes it ours with no network. */
    data class SharedAvailable(val bytes: Long) : ModelState
    /** Not on the phone. [partialBytes] > 0 means a paused download that [Garden.download] resumes. */
    data class Missing(val bytes: Long, val partialBytes: Long) : ModelState
}

/**
 * Shared on-device models for Skald, Earshot and future apps: any model, from the app's own [catalog].
 *
 * A file is shared with every app that lists the same bytes (same SHA-256), whatever the apps call the model or file.
 * Only for models the phone doesn't have built in (Gemini Nano and other system models are the app's business).
 * Order an app should follow: [state] (Ready / SharedAvailable / Missing) → [adopt] or [download] → [open].
 * Blocking calls are marked @WorkerThread. Shared files sit in Android's BlobStoreManager, keyed by SHA-256, readable
 * by any app; this app co-commits and leases every shared file it uses so the copy stays findable and alive even if
 * the app that first downloaded it is uninstalled.
 */
class Garden(
    context: Context,
    /** This app's models (e.g. [Catalog.fromAsset]). */
    val catalog: Catalog,
    /** Shown in Settings next to each shared file this app keeps. */
    private val leaseDescription: String = "Used by ${context.applicationInfo.loadLabel(context.packageManager)}",
    /** First retry delay for downloads (doubles each retry). Tests make it short. */
    retryDelayMs: Long = 2_000,
    /** Tries per file before [download] gives up (a later call resumes where it stopped). */
    downloadAttempts: Int = 6,
) {
    private val app = context.applicationContext
    private val bsm = app.getSystemService(BlobStoreManager::class.java)
    // Fixed names: they held private copies and download progress before handle scheme 2, and must keep doing so.
    private val prefs = app.getSharedPreferences("garden.v1", Context.MODE_PRIVATE)
    private val dir = File(app.filesDir, "garden/v1").apply { mkdirs() }
    private val names = Handles.bundled(app)
    private val http = Http(retryDelayMs, downloadAttempts)

    // ---- what's there ----------------------------------------------------------------------------------------------

    @WorkerThread
    fun state(id: String): ModelState {
        val m = catalog[id]
        val shared = m.files.map { sharedReady(it) }
        val private = m.files.map { privateReady(it) }
        // A model may be split (some files shared, some private: a shared download that failed halfway, then a
        // private one). It's Ready as soon as every file is usable one way or the other.
        if (m.files.indices.all { shared[it] || private[it] }) return ModelState.Ready(if (shared.any { it }) Where.SHARED else Where.PRIVATE)
        val missing = m.files.filterIndexed { i, _ -> !shared[i] && !private[i] }
        if (missing.all { visibleAs(it) != null }) return ModelState.SharedAvailable(missing.sumOf { it.size })
        return ModelState.Missing(missing.sumOf { it.size }, missing.sumOf { partial(it) })
    }

    /** This app can use the file right now: we own the shared copy and it's still there, or we have a private copy. */
    private fun usable(f: ModelFile) = sharedReady(f) || privateReady(f)
    private fun sharedReady(f: ModelFile) = ownedAs(f)?.let { visible(f, it) } ?: false

    // ---- getting it ------------------------------------------------------------------------------------------------

    /**
     * Makes another app's shared copy ours: co-commit (so it stays findable) + lease (so it stays on the phone).
     * No network. If this app's lease quota is too small, the files are copied to private storage instead.
     */
    @WorkerThread
    fun adopt(id: String): ModelState {
        val m = catalog[id]
        val toShare = m.files.filterNot { usable(it) }
        val shared = canShare(toShare)
        for (f in toShare) {
            val n = visibleAs(f) ?: throw GardenException.NotReady(id, "${f.name} is no longer shared")
            val src = openBlobOrNull(handle(f, n)) ?: throw GardenException.NotReady(id, "${f.name} is no longer shared")
            src.use {
                if (shared) {
                    // Co-commit under the name it's shared as: the system keeps one copy for every app.
                    commitStream(f, n, FileInputStream(it.fileDescriptor))
                    lease(f, n)
                } else {
                    writePrivate(f, FileInputStream(it.fileDescriptor))
                }
            }
        }
        return state(id)
    }

    /**
     * Downloads what's missing, resuming any earlier attempt. With [share] (and enough quota) the files go into the
     * shared store for other apps; otherwise they stay private to this app. A file another app finishes sharing in
     * the meantime is adopted instead of downloaded. The caller's app must hold the INTERNET permission.
     */
    @WorkerThread
    fun download(id: String, share: Boolean = true, isCancelled: () -> Boolean = { false }, onProgress: (done: Long, total: Long) -> Unit = { _, _ -> }) {
        val m = catalog[id]
        val todo = m.files.filterNot { usable(it) }
        val toShared = share && canShare(todo)
        var done = m.bytes - todo.sumOf { it.size }
        for (f in todo) {
            val there = if (toShared) visibleAs(f) else null
            if (there != null) {                       // someone else finished it: adopt, don't download
                openBlobOrNull(handle(f, there))?.use { commitStream(f, there, FileInputStream(it.fileDescriptor)); lease(f, there) }
                if (ownedAs(f) != null) { done += f.size; onProgress(done, m.bytes); continue }
            }
            val base = done
            val report = { have: Long -> onProgress(base + have, m.bytes) }
            if (toShared) downloadShared(f, isCancelled, report) else downloadPrivate(f, isCancelled, report)
            done += f.size
            onProgress(done, m.bytes)
        }
    }

    /**
     * Puts files this app already has (APK assets, or an older private copy from before Garden) into Garden without a
     * download. [source] returns a fresh stream for a file, or null to skip it. Hashes are checked.
     */
    @WorkerThread
    fun contribute(id: String, share: Boolean = true, source: (ModelFile) -> InputStream?) {
        val m = catalog[id]
        val todo = m.files.filterNot { usable(it) }
        val toShared = share && canShare(todo)
        for (f in todo) {
            val input = source(f) ?: continue
            input.use {
                if (toShared) {
                    val there = visibleAs(f)
                    val n = there ?: primary(f)
                    if (there != null) openBlobOrNull(handle(f, there))?.use { b -> commitStream(f, n, FileInputStream(b.fileDescriptor)) }
                    else commitStream(f, n, it)
                    lease(f, n)
                } else writePrivate(f, it)
            }
        }
    }

    /** Lets go of a model: releases this app's leases and deletes private copies. Shared copies other apps lease stay. */
    @WorkerThread
    fun remove(id: String) {
        val m = catalog[id]
        for (f in m.files) {
            for (n in names.names(f.sha256)) {
                if (owns(f, n)) try { bsm.releaseLease(handle(f, n)) } catch (e: Exception) { Log.w(TAG, "release ${f.name}: $e") }
                prefs.edit().remove(committedKey(f, n)).apply()
            }
            sessionId(f)?.let { abandon(f, it) }
            File(dir, f.sha256).delete(); File(dir, f.sha256 + ".part").delete()
        }
    }

    // ---- using it --------------------------------------------------------------------------------------------------

    /**
     * Opens a ready model for an engine (e.g. sherpa-onnx's `Xxx(assetManager, config)` constructors).
     * Every file is checked to open with the right size first, so an engine never gets a path it can't load
     * (sherpa-onnx abort()s the whole app on one). Keep the [OpenModel] open while the engine lives.
     */
    @WorkerThread
    fun open(id: String): OpenModel = open(listOf(id))

    /**
     * Opens several ready models behind ONE AssetManager, for engines that load two models through a single
     * AssetManager (sherpa-onnx speaker diarization: segmentation + voiceprints). Use [OpenModel.path] with the id.
     */
    @WorkerThread
    fun open(ids: List<String>): OpenModel {
        val models = ids.distinct().map { catalog[it] }
        val fds = LinkedHashMap<String, ParcelFileDescriptor>()
        try {
            for (m in models) for (f in m.files) {
                val id = m.id
                val pfd = ownedAs(f)?.let { openBlobOrNull(handle(f, it)) }
                    ?: (if (privateReady(f)) ParcelFileDescriptor.open(File(dir, f.sha256), ParcelFileDescriptor.MODE_READ_ONLY) else null)
                    ?: throw GardenException.NotReady(id, "${f.name} isn't on this phone")
                if (pfd.statSize != f.size) { pfd.close(); throw GardenException.NotReady(id, "${f.name} has the wrong size") }
                fds[Handles.assetPath(m, f)] = pfd
            }
            return OpenModel(models, BlobAssets.assetManager(app, fds), fds.values.toList())
        } catch (e: Exception) {
            fds.values.forEach { runCatching { it.close() } }
            throw e
        }
    }

    // ---- shared store ----------------------------------------------------------------------------------------------
    // A file may be shared under more than one name (Handles): new copies use the first; any one this app owns, or
    // that's in the store, counts.

    private fun primary(f: ModelFile) = names.names(f.sha256).first()

    private fun handle(f: ModelFile, n: Handles.Name): BlobHandle =
        BlobHandle.createWithSha256(Handles.digest(f.sha256), n.label, 0, n.tag)

    private fun openBlobOrNull(h: BlobHandle): ParcelFileDescriptor? =
        try { bsm.openBlob(h) } catch (e: SecurityException) { null } catch (e: IOException) { null }

    private fun visible(f: ModelFile, n: Handles.Name) = openBlobOrNull(handle(f, n))?.use { it.statSize == f.size } ?: false

    /** The name some app shares this file under, if any. */
    private fun visibleAs(f: ModelFile): Handles.Name? = names.names(f.sha256).firstOrNull { visible(f, it) }

    /** We committed it under [n] (recorded locally: the system can't be asked) and still lease it. */
    private fun owns(f: ModelFile, n: Handles.Name): Boolean =
        prefs.getBoolean(committedKey(f, n), false) && leased().any { it == handle(f, n) }

    private fun ownedAs(f: ModelFile): Handles.Name? = names.names(f.sha256).firstOrNull { owns(f, it) }

    private fun leased(): List<BlobHandle> = try { bsm.leasedBlobs } catch (e: IOException) { emptyList() }

    private fun canShare(files: List<ModelFile>) = Quota.fits(files.sumOf { it.size }, bsm.remainingLeaseQuotaBytes)

    private fun lease(f: ModelFile, n: Handles.Name) = bsm.acquireLease(handle(f, n), leaseDescription)

    /** Streams [input] into a new session for this file and commits it publicly; the system checks the SHA-256. */
    private fun commitStream(f: ModelFile, n: Handles.Name, input: InputStream) {
        val id = bsm.createSession(handle(f, n))
        try {
            bsm.openSession(id).use { s ->
                ParcelFileDescriptor.AutoCloseOutputStream(s.openWrite(0, f.size)).use { out -> copy(input, out) }
                commit(f, n, s)
            }
        } catch (e: Exception) { runCatching { bsm.abandonSession(id) }; throw e }
    }

    private fun commit(f: ModelFile, n: Handles.Name, s: BlobStoreManager.Session) {
        s.allowPublicAccess()
        val done = CountDownLatch(1); var code = -1
        val ex = Executors.newSingleThreadExecutor()
        try { s.commit(ex) { code = it; done.countDown() }; done.await() } finally { ex.shutdown() }
        if (code != 0) throw GardenException.Checksum(f.name)
        prefs.edit().putBoolean(committedKey(f, n), true).apply()
    }

    private fun downloadShared(f: ModelFile, isCancelled: () -> Boolean, onBytes: (Long) -> Unit) {
        val n = primary(f)
        var sid = sessionId(f) ?: newSession(f)
        val session = try { bsm.openSession(sid) } catch (e: Exception) { prefs.edit().remove(sessionKey(f)).remove(writtenKey(f)).apply(); bsm.openSession(newSession(f).also { sid = it }) }
        session.use { s ->
            // The resume point is our own count: Session.getSize() reports the whole preallocated length as soon as
            // openWrite() is called (found by tests/e2e.sh check 12), so it can't say how much really arrived.
            http.fetch(f, have = { written(f) }, isCancelled, onBytes) { offset, restart ->
                if (restart) Log.i(TAG, "${f.name}: server ignored Range, rewriting from 0")
                Counting(ParcelFileDescriptor.AutoCloseOutputStream(s.openWrite(offset, f.size - offset)), offset) { n ->
                    prefs.edit().putLong(writtenKey(f), n).apply()
                }
            }
            try { commit(f, n, s) } catch (e: GardenException.Checksum) { abandon(f, sid); throw e }
        }
        prefs.edit().remove(sessionKey(f)).remove(writtenKey(f)).apply()
        lease(f, n)
    }

    /** Bytes really written into this file's session, saved as they land (a lower bound: rewriting is harmless). */
    private fun written(f: ModelFile) = prefs.getLong(writtenKey(f), 0L)

    /** Passes writes through and reports the running total every MB and at close. */
    private class Counting(private val out: OutputStream, private var total: Long, private val save: (Long) -> Unit) : OutputStream() {
        private var saved = total
        override fun write(b: Int) { out.write(b); total++; maybeSave() }
        override fun write(b: ByteArray, off: Int, len: Int) { out.write(b, off, len); total += len; maybeSave() }
        private fun maybeSave() { if (total - saved >= 1_000_000) { out.flush(); save(total); saved = total } }
        override fun flush() = out.flush()
        override fun close() { out.use { it.flush() }; save(total) }
    }

    private fun newSession(f: ModelFile): Long =
        bsm.createSession(handle(f, primary(f))).also { prefs.edit().putLong(sessionKey(f), it).apply() }

    private fun sessionId(f: ModelFile): Long? = prefs.getLong(sessionKey(f), 0L).takeIf { it > 0 }

    private fun abandon(f: ModelFile, sid: Long) {
        runCatching { bsm.abandonSession(sid) }
        prefs.edit().remove(sessionKey(f)).remove(writtenKey(f)).apply()
    }

    private fun partial(f: ModelFile): Long =
        if (sessionId(f) != null) written(f) else File(dir, f.sha256 + ".part").length()

    // ---- private store (fallback when sharing is off or the quota is full) -----------------------------------------

    private fun privateReady(f: ModelFile) = File(dir, f.sha256).length() == f.size

    private fun downloadPrivate(f: ModelFile, isCancelled: () -> Boolean, onBytes: (Long) -> Unit) {
        val part = File(dir, f.sha256 + ".part")
        if (part.length() > f.size) part.delete()
        http.fetch(f, have = { part.length() }, isCancelled, onBytes) { offset, _ ->
            java.io.RandomAccessFile(part, "rw").use { it.setLength(offset) }
            java.io.FileOutputStream(part, true)
        }
        if (sha256(FileInputStream(part)) != f.sha256) { part.delete(); throw GardenException.Checksum(f.name) }
        check(part.renameTo(File(dir, f.sha256))) { "couldn't save ${f.name}" }
    }

    private fun writePrivate(f: ModelFile, input: InputStream) {
        val part = File(dir, f.sha256 + ".part")
        val md = MessageDigest.getInstance("SHA-256")
        java.io.FileOutputStream(part).use { out -> copy(input, out, md) }
        if (hex(md.digest()) != f.sha256 || part.length() != f.size) { part.delete(); throw GardenException.Checksum(f.name) }
        check(part.renameTo(File(dir, f.sha256))) { "couldn't save ${f.name}" }
    }

    // Keyed by the handle's tag, as before scheme 2, so keys written by older versions still match.
    private fun committedKey(f: ModelFile, n: Handles.Name) = "committed:" + n.tag + ":" + f.sha256
    private fun sessionKey(f: ModelFile) = "session:" + primary(f).tag + ":" + f.sha256
    private fun writtenKey(f: ModelFile) = "written:" + primary(f).tag + ":" + f.sha256

    internal companion object {
        const val TAG = "Garden"

        fun copy(input: InputStream, out: OutputStream, md: MessageDigest? = null) {
            val buf = ByteArray(1 shl 20)
            while (true) { val n = input.read(buf); if (n < 0) break; out.write(buf, 0, n); md?.update(buf, 0, n) }
        }

        fun sha256(input: InputStream): String = input.use {
            val md = MessageDigest.getInstance("SHA-256"); val buf = ByteArray(1 shl 20)
            while (true) { val n = it.read(buf); if (n < 0) break; md.update(buf, 0, n) }
            hex(md.digest())
        }

        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    }
}

/** Pure quota rule, kept separate so it can be unit-tested. */
object Quota {
    fun fits(neededBytes: Long, remainingLeaseQuota: Long) = neededBytes <= remainingLeaseQuota
}
