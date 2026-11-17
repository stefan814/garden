package io.github.stefan814.garden.harness

import android.app.Activity
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractor
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import io.github.stefan814.garden.Catalog
import io.github.stefan814.garden.Garden
import io.github.stefan814.garden.ModelState
import kotlin.math.sqrt

/**
 * Test driver for the Garden library, installed as two packages (…harness.a, …harness.b) so cross-app sharing can be
 * exercised. `adb shell am start -n <pkg>/io.github.stefan814.garden.harness.Harness --es do <step> --es model <id>
 * [--es catalog test] [--ez share false] [--ei attempts 1]`. Every line is logged with tag GARDEN; tests/e2e.sh asserts.
 */
class Harness : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val step = intent.getStringExtra("do") ?: "state"
        val model = intent.getStringExtra("model") ?: "silero-vad-v5"
        if (step == "svcload") {
            // Same load, but from a Service: Earshot loads in RecorderService, Skald in a worker.
            startService(Intent(this, LoadService::class.java).putExtras(intent)); finish(); return
        }
        Thread {
            Steps(this, intent).run(step, model)
            runOnUiThread { finish() }
        }.start()
    }
}

class LoadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent, flags: Int, startId: Int): Int {
        Thread {
            Steps(this, intent).run("load", intent.getStringExtra("model") ?: "silero-vad-v5", where = "service")
            stopSelf(startId)
        }.start()
        return START_NOT_STICKY
    }
}

private class Steps(private val ctx: Context, intent: Intent) {
    private val catalog = if (intent.getStringExtra("catalog") == "test")
        Catalog.parse(ctx.assets.open("test-catalog.json").bufferedReader().use { it.readText() }
        // On a real phone the host server is reached through `adb reverse` at 127.0.0.1 instead of the emulator's 10.0.2.2.
        .replace("10.0.2.2", intent.getStringExtra("host") ?: "10.0.2.2"), allowSameFile = true) else Catalog.fromAsset(ctx, "real-catalog.json")
    private val garden = Garden(ctx, catalog, retryDelayMs = 200, downloadAttempts = intent.getIntExtra("attempts", 4))
    private val share = intent.getBooleanExtra("share", true)
    private val skip = intent.getStringExtra("skip")

    fun run(step: String, id: String, where: String = "activity") {
        log("== ${ctx.packageName} $step $id")
        try {
            when (step) {
                "state" -> {}
                "download" -> {
                    var last = -1L
                    garden.download(id, share) { done, total -> if (done == total || done - last > 10_000_000) { log("progress $done/$total"); last = done } }
                }
                "adopt" -> garden.adopt(id)
                "contribute" -> garden.contribute(id, share) { f ->
                    // Any bundled copy of this file name (test models reuse the real ones); --es skip <name> leaves one out.
                    if (f.name == skip) null
                    else ctx.assets.list("models").orEmpty().firstNotNullOfOrNull { d -> runCatching { ctx.assets.open("models/$d/${f.name}") }.getOrNull() }
                }
                "remove" -> garden.remove(id)
                "load" -> load(id, where, closeEarly = false)
                "loadclose" -> load(id, where, closeEarly = true)
                "fdloop" -> {
                    // Earshot's recorder service rebuilds engines often: open/load/close must not leak descriptors.
                    fun fds() = java.io.File("/proc/self/fd").list()!!.size
                    load(id, where, closeEarly = false); Runtime.getRuntime().gc(); Thread.sleep(300)
                    val before = fds()
                    repeat(30) { load(id, where, closeEarly = false, quiet = true) }
                    Runtime.getRuntime().gc(); System.runFinalization(); Runtime.getRuntime().gc(); Thread.sleep(300)
                    log("FDS before=$before after=${fds()} (30 open/load/close cycles)")
                }
                else -> log("unknown step $step")
            }
        } catch (t: Throwable) { log("ERROR ${t.javaClass.simpleName}: ${t.message}") }
        log("STATE $id = ${describe(garden.state(id))}")
        log("== done $step")
    }

    private fun describe(s: ModelState) = when (s) {
        is ModelState.Ready -> "Ready(${s.where})"
        is ModelState.SharedAvailable -> "SharedAvailable"
        is ModelState.Missing -> "Missing(partial=${if (s.partialBytes > 0) "yes" else "no"})"
    }

    /** Opens via Garden and runs the right engine. [closeEarly]: close the OpenModel right after the engine is built. */
    private fun load(id: String, where: String, closeEarly: Boolean, quiet: Boolean = false) {
        val m = catalog[id]
        val open = garden.open(id)
        val audio = wav()
        val result = when (m.capability) {
            "asr.en" -> {
                val rec = OfflineRecognizer(open.assets, OfflineRecognizerConfig(
                    featConfig = FeatureConfig(sampleRate = 16_000, featureDim = 80, dither = 0f),
                    modelConfig = OfflineModelConfig(
                        transducer = OfflineTransducerModelConfig(open.path("encoder.int8.onnx"), open.path("decoder.int8.onnx"), open.path("joiner.int8.onnx")),
                        modelType = "nemo_transducer", tokens = open.path("tokens.txt"), numThreads = 4, provider = "cpu"),
                    decodingMethod = "greedy_search"))
                if (closeEarly) open.close()
                val st = rec.createStream(); st.acceptWaveform(audio, 16_000); rec.decode(st)
                "text='${rec.getResult(st).text.trim()}'".also { st.release(); rec.release() }
            }
            "vad" -> {
                val vad = Vad(open.assets, VadModelConfig(SileroVadModelConfig(model = open.path("vad.onnx"), threshold = 0.35f,
                    minSilenceDuration = 0.5f, minSpeechDuration = 0.25f, windowSize = 512, maxSpeechDuration = 15f), sampleRate = 16_000, numThreads = 1))
                if (closeEarly) open.close()
                var i = 0; var speech = 0
                while (i + 512 <= audio.size) { vad.acceptWaveform(audio.copyOfRange(i, i + 512)); if (vad.isSpeechDetected()) speech++; i += 512 }
                "speechWindows=$speech".also { vad.release() }
            }
            "speaker.embedding" -> {
                val ex = SpeakerEmbeddingExtractor(open.assets, SpeakerEmbeddingExtractorConfig(model = open.path("embed.onnx"), numThreads = 2))
                if (closeEarly) open.close()
                val s = ex.createStream(); s.acceptWaveform(audio, 16_000); s.inputFinished()
                val v = ex.compute(s); s.release(); ex.release()
                "dim=${v.size} norm=${"%.4f".format(sqrt(v.sumOf { (it * it).toDouble() }))}"
            }
            else -> "no engine for ${m.capability}"
        }
        open.close()
        if (!quiet) log("LOADED $id in $where: $result")
    }

    private fun wav(): FloatArray {
        val b = ctx.assets.open("test.wav").use { it.readBytes() }
        val d = (0 until b.size - 4).first { String(b, it, 4) == "data" } + 8
        val pcm = java.nio.ByteBuffer.wrap(b, d, b.size - d).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        return FloatArray(pcm.remaining()) { pcm.get(it) / 32768f }
    }

    private fun log(m: String) = Log.i("GARDEN", m)
}
