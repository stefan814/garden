package io.github.stefan814.gardenspike

import android.app.Activity
import android.app.blob.BlobHandle
import android.app.blob.BlobStoreManager
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.system.Os
import android.util.Log
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractor
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Throwaway test for the Garden design gate: can app B load, in sherpa-onnx, a model that app A put in
 * Android's shared blob store? Driven by `adb shell am start -n <pkg>/io.github.stefan814.gardenspike.Spike --es do <step>`.
 * Every result line is logged with tag GARDEN.
 */
class Spike : Activity() {
    private val bsm by lazy { getSystemService(BlobStoreManager::class.java) }

    // The two files both Skald and Earshot already ship, with the exact SHA-256 they pin.
    private val files = listOf(
        "embed.onnx" to "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",
        "vad.onnx" to "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
        "asr/encoder.int8.onnx" to "0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657",
        "asr/decoder.int8.onnx" to "f7c331c5504c2e593c76ed22b728e3f554af6c4a383dde862e719ced08b1da19",
        "asr/joiner.int8.onnx" to "bf7dff69e9f2cdbe9943d70da358f38b361c115ba0105bae7e908e0d6ec782f6",
        "asr/tokens.txt" to "450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10",
    )

    private fun handle(name: String, sha: String): BlobHandle =
        BlobHandle.createWithSha256(hex(sha), "garden:$name", 0, "garden/$name")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val step = intent.getStringExtra("do") ?: "status"
        Thread {
            log("== $packageName: $step")
            try {
                when (step) {
                    "contribute" -> contribute()
                    "load" -> load()
                    "asr" -> asr()
                    "asrlocal" -> recognize(assets, "asr", "own APK assets")
                    "recommit" -> recommit()
                    "lease" -> files.forEach { (n, s) -> lease(handle(n, s), n) }
                    "release" -> files.forEach { (n, s) -> bsm.releaseLease(handle(n, s)); log("released $n") }
                    else -> status()
                }
            } catch (t: Throwable) { log("FAILED $step: $t") }
            log("== done $step")
            runOnUiThread { finish() }
        }.start()
    }

    private fun status() {
        log("quota remaining = ${bsm.remainingLeaseQuotaBytes / 1_048_576} MiB")
        log("leased = ${bsm.leasedBlobs.map { it.label }}")
        files.forEach { (n, s) ->
            val ok = try { bsm.openBlob(handle(n, s)).close(); true } catch (e: SecurityException) { false }
            log("$n visible = $ok")
        }
    }

    private fun contribute() {
        status()
        for ((name, sha) in files) {
            val h = handle(name, sha)
            val exists = try { bsm.openBlob(h).close(); true } catch (e: SecurityException) { false }
            if (exists) { log("$name already in store, not contributing"); lease(h, name); continue }
            val size = assets.openFd(name).use { it.length }
            val id = bsm.createSession(h)
            bsm.openSession(id).use { s ->
                ParcelFileDescriptor.AutoCloseOutputStream(s.openWrite(0, size)).use { out -> assets.open(name).use { it.copyTo(out, 1 shl 20) } }
                s.allowPublicAccess()
                val done = CountDownLatch(1); var code = -1
                s.commit(Executors.newSingleThreadExecutor()) { code = it; done.countDown() }
                done.await()
                log("$name committed, result=$code (0 = success; the system checks the SHA-256), $size bytes")
            }
            lease(h, name)
        }
        status()
    }

    /** Co-commit blobs we can already read (same handle, public access), so they stay findable if the first committer goes. */
    private fun recommit() {
        for ((name, sha) in files) {
            val h = handle(name, sha)
            val pfd = try { bsm.openBlob(h) } catch (e: SecurityException) { log("$name not visible, skipped"); continue }
            pfd.use { src ->
                val id = bsm.createSession(h)
                bsm.openSession(id).use { s ->
                    ParcelFileDescriptor.AutoCloseOutputStream(s.openWrite(0, src.statSize)).use { out -> FileInputStream(src.fileDescriptor).copyTo(out, 1 shl 20) }
                    s.allowPublicAccess()
                    val done = CountDownLatch(1); var code = -1
                    s.commit(Executors.newSingleThreadExecutor()) { code = it; done.countDown() }
                    done.await()
                    log("$name co-committed, result=$code")
                }
            }
            lease(h, name)
        }
    }

    private fun lease(h: BlobHandle, name: String) {
        bsm.acquireLease(h, "Garden test: $name")
        log("leased $name; quota remaining = ${bsm.remainingLeaseQuotaBytes / 1_048_576} MiB")
    }

    private fun load() {
        status()
        val audio = testAudio()
        val (en, es) = files[0]; val (vn, vs) = files[1]

        bsm.openBlob(handle(en, es)).use { pfd ->
            val proc = "/proc/self/fd/${pfd.fd}"
            val real = try { Os.readlink(proc) } catch (e: Exception) { "readlink failed: $e" }
            log("$en fd=${pfd.fd} -> $real, statSize=${pfd.statSize}")

            // 1. Java open through the /proc path, and its checksum.
            try { log("1. java open $proc sha ok = ${sha256(FileInputStream(proc).use { it.readBytes() }) == es}") }
            catch (e: Exception) { log("1. java open $proc FAILED: $e") }

            // 2. Java open of the real blobstore path (expected to be denied).
            try { FileInputStream(real).use { it.read() }; log("2. open real path OK (unexpected)") }
            catch (e: Exception) { log("2. open real path denied (expected): ${e.message}") }

            // 3. Serve the blob's fd as an asset (AssetsProvider, API 30) and let sherpa load it via AssetManager.
            //    Nothing is reopened by path, so SELinux has nothing to deny.
            val viaProc = try {
                val t0 = System.nanoTime()
                embedAsset(blobAssets(mapOf("garden/$en" to pfd)), "garden/$en", audio)
                    .also { log("3. sherpa embed via AssetsProvider OK in ${(System.nanoTime() - t0) / 1_000_000} ms: ${fmt(it)}") }
            } catch (t: Throwable) { log("3. AssetsProvider route FAILED: $t"); null }

            // 4. Reference: copy to private storage and load, to check the result is identical.
            val copy = File(cacheDir, en)
            copy.outputStream().use { FileInputStream(pfd.fileDescriptor).copyTo(it) }
            val viaCopy = embed(copy.path, audio)
            log("4. sherpa embed via private copy: ${fmt(viaCopy)}")
            log("RESULT embedding identical = ${viaProc != null && viaProc.contentEquals(viaCopy)}")
            copy.delete()
        }

        bsm.openBlob(handle(vn, vs)).use { pfd ->
            try {
                val am = blobAssets(mapOf("garden/$vn" to pfd))
                val vad = Vad(am, VadModelConfig(
                    sileroVadModelConfig = SileroVadModelConfig(model = "garden/$vn", threshold = 0.35f, minSilenceDuration = 0.5f,
                        minSpeechDuration = 0.25f, windowSize = 512, maxSpeechDuration = 15f),
                    sampleRate = 16_000, numThreads = 1))
                var i = 0
                while (i + 512 <= audio.size) { vad.acceptWaveform(audio.copyOfRange(i, i + 512)); i += 512 }
                log("RESULT vad via AssetsProvider loaded OK, ran ${audio.size / 512} windows")
                vad.release()
            } catch (t: Throwable) { log("RESULT vad via AssetsProvider FAILED: $t") }
        }
    }

    /** Parakeet 110M straight from the shared store: four blobs served as assets, no copies. */
    private fun asr() {
        status()
        val asrFiles = files.filter { it.first.startsWith("asr/") }
        val pfds = asrFiles.associate { (n, sha) -> "garden/$n" to bsm.openBlob(handle(n, sha)) }
        try { recognize(blobAssets(pfds), "garden/asr", "shared store") }
        finally { pfds.values.forEach { it.close() } }
    }

    private fun recognize(am: android.content.res.AssetManager, dir: String, how: String) {
        val rss0 = rssMb(); val pss0 = pssMb(); val t0 = System.nanoTime()
        val rec = com.k2fsa.sherpa.onnx.OfflineRecognizer(am, com.k2fsa.sherpa.onnx.OfflineRecognizerConfig(
            featConfig = com.k2fsa.sherpa.onnx.FeatureConfig(sampleRate = 16_000, featureDim = 80, dither = 0f),
            modelConfig = com.k2fsa.sherpa.onnx.OfflineModelConfig(
                transducer = com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig(
                    encoder = "$dir/encoder.int8.onnx", decoder = "$dir/decoder.int8.onnx", joiner = "$dir/joiner.int8.onnx"),
                modelType = "nemo_transducer", tokens = "$dir/tokens.txt", numThreads = 4, provider = "cpu"),
            decodingMethod = "greedy_search"))
        val loadMs = (System.nanoTime() - t0) / 1_000_000
        val wav = assets.open("test.wav").use { it.readBytes() }
        val d = (0 until wav.size - 4).first { wav[it] == 'd'.code.toByte() && String(wav, it, 4) == "data" } + 8
        val pcm = java.nio.ByteBuffer.wrap(wav, d, wav.size - d).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val samples = FloatArray(pcm.remaining()) { pcm.get(it) / 32768f }
        val t1 = System.nanoTime()
        val st = rec.createStream(); st.acceptWaveform(samples, 16_000); rec.decode(st)
        val text = rec.getResult(st).text.trim()
        log("RESULT [$how] parakeet load ${loadMs} ms, decode ${(System.nanoTime() - t1) / 1_000_000} ms for ${samples.size / 16} ms audio; " +
            "RSS ${rss0}->${rssMb()} MB, PSS ${pss0}->${pssMb()} MB; text = '$text'")
        st.release(); rec.release()
    }

    private fun pssMb(): Long { val m = android.os.Debug.MemoryInfo(); android.os.Debug.getMemoryInfo(m); return m.totalPss / 1024L }

    private fun rssMb() = File("/proc/self/status").readLines().first { it.startsWith("VmRSS") }.filter { it.isDigit() }.toLong() / 1024

    /** An AssetManager whose assets at the given paths are the given blob fds (read in place, never reopened). */
    private fun blobAssets(blobs: Map<String, ParcelFileDescriptor>): android.content.res.AssetManager {
        val provider = object : android.content.res.loader.AssetsProvider {
            override fun loadAssetFd(path: String, accessMode: Int): android.content.res.AssetFileDescriptor? {
                log("   provider asked for '$path'")
                val p = blobs[path] ?: blobs[path.removePrefix("assets/")] ?: return null
                return android.content.res.AssetFileDescriptor(p.dup(), 0, p.statSize)
            }
        }
        val loader = android.content.res.loader.ResourcesLoader()
        loader.addProvider(android.content.res.loader.ResourcesProvider.empty(provider))
        val ctx = createConfigurationContext(android.content.res.Configuration(resources.configuration))
        ctx.resources.addLoaders(loader)
        val am = ctx.assets
        for (k in blobs.keys) try { am.open(k).use { log("   java AssetManager.open($k) OK, available=${it.available()}") } }
            catch (e: Exception) { log("   java AssetManager.open($k) FAILED: $e") }
        return am
    }

    private fun embedAsset(am: android.content.res.AssetManager, path: String, audio: FloatArray): FloatArray {
        val ex = SpeakerEmbeddingExtractor(am, SpeakerEmbeddingExtractorConfig(model = path, numThreads = 2))
        val s = ex.createStream()
        s.acceptWaveform(audio, 16_000); s.inputFinished()
        val v = ex.compute(s)
        s.release(); ex.release()
        return v
    }

    /** Copies a read-only blob into a memfd this process owns (re-openable through /proc, unlike the blob). */
    private fun memfdCopy(blob: ParcelFileDescriptor, name: String): ParcelFileDescriptor {
        val fd = Os.memfd_create("garden-$name", 0)
        val pfd = ParcelFileDescriptor.dup(fd); Os.close(fd)
        // Streams over a borrowed FileDescriptor close it on close(), so copy without closing them.
        val out = java.io.FileOutputStream(pfd.fileDescriptor); FileInputStream(blob.fileDescriptor).copyTo(out, 1 shl 20); out.flush()
        Os.lseek(blob.fileDescriptor, 0, android.system.OsConstants.SEEK_SET)
        return pfd
    }

    private fun embed(path: String, audio: FloatArray): FloatArray {
        val ex = SpeakerEmbeddingExtractor(null, SpeakerEmbeddingExtractorConfig(model = path, numThreads = 2))
        val s = ex.createStream()
        s.acceptWaveform(audio, 16_000); s.inputFinished()
        val v = ex.compute(s)
        s.release(); ex.release()
        return v
    }

    /** 3 s of a voice-ish buzz (harmonics + noise), the same every run. */
    private fun testAudio(): FloatArray {
        val r = Random(7)
        return FloatArray(48_000) { i ->
            val t = i / 16_000.0
            ((0.3 * sin(2 * PI * 140 * t) + 0.15 * sin(2 * PI * 280 * t) + 0.08 * sin(2 * PI * 420 * t)) *
                (0.6 + 0.4 * sin(2 * PI * 3 * t)) + 0.02 * (r.nextDouble() - 0.5)).toFloat()
        }
    }

    private fun fmt(v: FloatArray) = "dim=${v.size} norm=${"%.4f".format(sqrt(v.sumOf { (it * it).toDouble() }))} " +
        "first=${v.take(3).joinToString { "%.4f".format(it) }}"

    private fun log(m: String) { Log.i("GARDEN", m) }
    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
