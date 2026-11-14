package io.github.stefan814.garden

import android.content.Context
import org.json.JSONObject

/** One file of a model, pinned by size and SHA-256. Every url serves exactly these bytes. */
data class ModelFile(val name: String, val size: Long, val sha256: String, val urls: List<String>)

/** A model: one or more files that an engine loads together. */
data class Model(
    val id: String,
    val title: String,
    val capability: String,
    val license: String,
    val files: List<ModelFile>,
) {
    val bytes: Long get() = files.sumOf { it.size }
    fun file(name: String): ModelFile = files.firstOrNull { it.name == name } ?: error("$id has no file $name")
}

/**
 * The shared list of models. Handles in Android's shared store are built only from this, so two apps that ship the
 * same catalog entry always agree on a blob's identity. See catalog/garden-catalog.json.
 */
class Catalog(val scheme: Int, val models: List<Model>) {
    operator fun get(id: String): Model = models.firstOrNull { it.id == id } ?: throw GardenException.UnknownModel(id)

    fun forCapability(capability: String): List<Model> = models.filter { it.capability == capability }

    companion object {
        const val ASSET = "garden-catalog.json"
        private val ID = Regex("[a-z0-9][a-z0-9.\\-]{0,47}")
        private val NAME = Regex("[A-Za-z0-9][A-Za-z0-9._\\-]{0,47}")
        private val SHA = Regex("[0-9a-f]{64}")

        /** The catalog bundled in the library (merged into the app's assets). */
        fun bundled(context: Context): Catalog = parse(context.assets.open(ASSET).bufferedReader().use { it.readText() })

        /** [allowSameFile] is for test catalogs only: real ones must not list one file in two models. */
        fun parse(json: String, allowSameFile: Boolean = false): Catalog {
            val root = JSONObject(json)
            val scheme = root.getInt("scheme")
            require(scheme == Handles.SCHEME) { "catalog scheme $scheme, this library knows ${Handles.SCHEME}" }
            val arr = root.getJSONArray("models")
            val models = (0 until arr.length()).map { i ->
                val m = arr.getJSONObject(i)
                val files = m.getJSONArray("files").let { fa ->
                    (0 until fa.length()).map { j ->
                        val f = fa.getJSONObject(j)
                        val urls = f.getJSONArray("urls").let { ua -> (0 until ua.length()).map { ua.getString(it) } }
                        ModelFile(f.getString("name"), f.getLong("size"), f.getString("sha256"), urls)
                    }
                }
                Model(m.getString("id"), m.getString("title"), m.getString("capability"), m.optString("license"), files)
            }
            validate(models, allowSameFile)
            return Catalog(scheme, models)
        }

        private fun validate(models: List<Model>, allowSameFile: Boolean) {
            val ids = HashSet<String>()
            val hashes = HashMap<String, String>()
            for (m in models) {
                require(ID.matches(m.id)) { "bad model id '${m.id}'" }
                require(ids.add(m.id)) { "duplicate model id '${m.id}'" }
                require(m.files.isNotEmpty()) { "${m.id} has no files" }
                val names = HashSet<String>()
                for (f in m.files) {
                    require(NAME.matches(f.name)) { "${m.id}: bad file name '${f.name}'" }
                    require(names.add(f.name)) { "${m.id}: duplicate file '${f.name}'" }
                    require(SHA.matches(f.sha256)) { "${m.id}/${f.name}: sha256 must be 64 lowercase hex" }
                    // Private copies are stored by hash, so one file in two models would let removing one break the other.
                    hashes.put(f.sha256, "${m.id}/${f.name}")?.let { if (!allowSameFile) error("${m.id}/${f.name} is the same file as $it") }
                    require(f.size > 0) { "${m.id}/${f.name}: size must be positive" }
                    require(f.urls.all { it.startsWith("https://") || it.startsWith("http://") }) { "${m.id}/${f.name}: bad url" }
                    // The system rejects longer labels/tags (AOSP BlobHandle limits), so fail here, not on a phone.
                    require(Handles.label(m, f).length <= Handles.MAX_LABEL) { "${m.id}/${f.name}: label too long" }
                    require(Handles.tag(m, f).length <= Handles.MAX_TAG) { "${m.id}/${f.name}: tag too long" }
                }
            }
        }
    }
}

/**
 * Frozen naming for Android shared-store handles. A handle is sha256 + label + tag + expiry: changing any of these
 * for a published file makes a second, separate blob. Bump [SCHEME] (and the catalog's "scheme") only on purpose.
 */
object Handles {
    const val SCHEME = 1
    const val MAX_LABEL = 100
    const val MAX_TAG = 128

    /** Shown to the user in Settings > Storage, so it should read as words. Built from id + name, never from title. */
    fun label(m: Model, f: ModelFile) = "Garden model ${m.id} (${f.name})"
    fun tag(m: Model, f: ModelFile) = "garden/v$SCHEME/${m.id}/${f.name}"
    /** Where the file appears inside an [OpenModel]'s AssetManager. */
    fun assetPath(m: Model, f: ModelFile) = "garden/${m.id}/${f.name}"

    fun digest(sha256: String) = ByteArray(32) { sha256.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

sealed class GardenException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class UnknownModel(id: String) : GardenException("No model '$id' in the Garden catalog")
    /** The model isn't fully on the phone (or a shared copy vanished): never hand an engine a path it can't open. */
    class NotReady(id: String, why: String) : GardenException("Model '$id' isn't ready: $why")
    class Checksum(file: String) : GardenException("$file didn't match its SHA-256; it will be downloaded again")
    class Download(file: String, cause: Throwable) : GardenException("Couldn't download $file: ${cause.message}", cause)
}
