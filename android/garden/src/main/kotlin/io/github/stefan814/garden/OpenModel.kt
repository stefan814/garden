package io.github.stefan814.garden

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.content.res.AssetManager
import android.content.res.Configuration
import android.content.res.loader.AssetsProvider
import android.content.res.loader.ResourcesLoader
import android.content.res.loader.ResourcesProvider
import android.os.ParcelFileDescriptor
import java.io.Closeable

/**
 * A model ready for an engine. Pass [assets] and [path] to an engine's AssetManager constructor, e.g.
 * `SpeakerEmbeddingExtractor(open.assets, SpeakerEmbeddingExtractorConfig(model = open.path("embed.onnx")))`.
 * Close it when the engine is released.
 */
class OpenModel internal constructor(
    /** Every model opened together (see [Garden.open] with several ids); [model] is the first. */
    val models: List<Model>,
    val assets: AssetManager,
    private val fds: List<ParcelFileDescriptor>,
) : Closeable {
    val model: Model get() = models.first()
    fun path(fileName: String): String = Handles.assetPath(model, model.file(fileName))
    /** A file of one of several models opened together, for engines that take two models through one AssetManager. */
    fun path(id: String, fileName: String): String = models.first { it.id == id }.let { Handles.assetPath(it, it.file(fileName)) }
    override fun close() = fds.forEach { runCatching { it.close() } }
}

/**
 * Serves file descriptors as assets. This is the only way we found for one app to load another app's shared file:
 * Android's SELinux policy blocks reopening any fd by path (/proc/self/fd/N, memfd, the blob's real path), but an
 * AssetsProvider hands the engine the descriptor itself. Verified on API 36 emulator and Pixel 10a (API 37).
 */
internal object BlobAssets {
    fun assetManager(context: Context, byPath: Map<String, ParcelFileDescriptor>): AssetManager {
        val provider = object : AssetsProvider {
            override fun loadAssetFd(path: String, accessMode: Int): AssetFileDescriptor? {
                // The framework asks for "assets/<path>" (and for resources.arsc, which we don't have).
                val p = byPath[path.removePrefix("assets/")] ?: return null
                return AssetFileDescriptor(p.dup(), 0, p.statSize)
            }
        }
        val loader = ResourcesLoader().apply { addProvider(ResourcesProvider.empty(provider)) }
        // A private Resources, so the app's own resources/assets never see the loader.
        val ctx = context.createConfigurationContext(Configuration(context.resources.configuration))
        ctx.resources.addLoaders(loader)
        return ctx.assets
    }
}
