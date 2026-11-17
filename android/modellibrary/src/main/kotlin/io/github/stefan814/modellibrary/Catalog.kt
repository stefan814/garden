package io.github.stefan814.modellibrary

import android.content.Context
import org.json.JSONObject

/** One file of a model, pinned by size and SHA-256. Every url serves exactly these bytes. */
data class ModelFile(val name: String, val size: Long, val sha256: String, val urls: List<String>)

/**
 * A model: one or more files that an engine loads together. [id] and the file names are this app's own words for
 * it; sharing between apps goes by each file's SHA-256 alone, so two apps may call the same file anything they like.
 */
data class Model(
    val id: String,
    val files: List<ModelFile>,
    val title: String = id,
    val capability: String = "",
    val license: String = "",
) {
    val bytes: Long get() = files.sumOf { it.size }
    fun file(name: String): ModelFile = files.firstOrNull { it.name == name } ?: error("$id has no file $name")
}

/**
 * The models one app uses. Each app brings its own (any model, from anywhere): the Model Library shares a file with every other
 * app that lists the same bytes (same SHA-256), whatever either app calls it. Build one in code or with [parse].
 *
 * [allowSameFile] is for tests only: within one app's list a file must not be in two models, or removing one model
 * would take the file away from the other.
 */
class Catalog(val models: List<Model>, allowSameFile: Boolean = false) {
    init { validate(models, allowSameFile) }

    operator fun get(id: String): Model = models.firstOrNull { it.id == id } ?: throw ModelLibraryException.UnknownModel(id)

    fun forCapability(capability: String): List<Model> = models.filter { it.capability == capability }

    companion object {
        /** The JSON layout version ("format"; older files call it "scheme"). Only 1 exists. */
        const val FORMAT = 1
        private val ID = Regex("[a-z0-9][a-z0-9.\\-]{0,47}")
        private val NAME = Regex("[A-Za-z0-9][A-Za-z0-9._\\-]{0,47}")
        private val SHA = Regex("[0-9a-f]{64}")

        /** A catalog JSON file in this app's assets. */
        fun fromAsset(context: Context, name: String): Catalog =
            parse(context.assets.open(name).bufferedReader().use { it.readText() })

        /**
         * {"format": 1, "models": [{"id", "files": [{"name", "size", "sha256", "urls"}], "title"?, "capability"?,
         * "license"?}]}. "format" may be left out.
         */
        fun parse(json: String, allowSameFile: Boolean = false): Catalog {
            val root = JSONObject(json)
            val format = root.optInt("format", root.optInt("scheme", FORMAT))
            require(format == FORMAT) { "catalog format $format, this library knows $FORMAT" }
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
                val id = m.getString("id")
                Model(id, files, m.optString("title", id), m.optString("capability"), m.optString("license"))
            }
            return Catalog(models, allowSameFile)
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
                    hashes.put(f.sha256, "${m.id}/${f.name}")?.let { if (!allowSameFile) error("${m.id}/${f.name} is the same file as $it") }
                    require(f.size > 0) { "${m.id}/${f.name}: size must be positive" }
                    require(f.urls.all { it.startsWith("https://") || it.startsWith("http://") }) { "${m.id}/${f.name}: bad url" }
                }
            }
        }
    }
}

/**
 * Naming for Android shared-store handles. A handle is sha256 + label + tag + expiry, and every app must build exactly
 * the same one for a file or Android keeps separate copies. So a handle depends on the file's bytes only:
 * The names say "Garden", the library's old name, on purpose: they are each file's identity on phones, so renaming
 * them would orphan every shared copy and stop sharing with apps on older versions.
 * - Scheme 2 (every file not in [legacy]): label [LABEL], tag "garden/v2/<sha256>".
 * - Scheme 1 (files the library's own catalog listed (when it was called Garden) before apps brought their own, kept in assets/[LEGACY_ASSET]):
 *   label "Garden model <id> (<name>)", tag "garden/v1/<id>/<name>", from the id and name that catalog gave them.
 *   Phones already hold these, and apps on older versions look for them there.
 * Never change either: a different handle for a published file means a second copy on every phone.
 */
class Handles internal constructor(
    /** sha256 → the (model id, file name) pairs its scheme-1 handles were built from. */
    private val legacy: Map<String, List<Pair<String, String>>>,
) {
    /** A handle's label and tag; the sha256 and expiry (0) come from the file. */
    data class Name(val label: String, val tag: String)

    /** Every name this file may be shared under, the one new copies use first. */
    fun names(sha256: String): List<Name> =
        legacy[sha256]?.map { (id, name) -> v1(id, name) }?.takeIf { it.isNotEmpty() } ?: listOf(v2(sha256))

    companion object {
        const val LABEL = "Garden shared model file"
        const val LEGACY_ASSET = "garden-v1-handles.json"
        const val MAX_LABEL = 100
        const val MAX_TAG = 128

        fun v1(id: String, name: String) = Name("Garden model $id ($name)", "garden/v1/$id/$name")
        fun v2(sha256: String) = Name(LABEL, "garden/v2/$sha256")

        /** Where the file appears inside an [OpenModel]'s AssetManager (this app's own names). */
        fun assetPath(m: Model, f: ModelFile) = "modellibrary/${m.id}/${f.name}"

        fun digest(sha256: String) = ByteArray(32) { sha256.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        fun parseLegacy(json: String): Handles {
            val files = JSONObject(json).getJSONObject("files")
            val map = HashMap<String, List<Pair<String, String>>>()
            for (sha in files.keys()) {
                val arr = files.getJSONArray(sha)
                map[sha] = (0 until arr.length()).map { arr.getJSONArray(it).let { p -> p.getString(0) to p.getString(1) } }
            }
            return Handles(map)
        }

        fun bundled(context: Context): Handles =
            parseLegacy(context.assets.open(LEGACY_ASSET).bufferedReader().use { it.readText() })
    }
}

sealed class ModelLibraryException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class UnknownModel(id: String) : ModelLibraryException("No model '$id' in this app's model list")
    /** The model isn't fully on the phone (or a shared copy vanished): never hand an engine a path it can't open. */
    class NotReady(id: String, why: String) : ModelLibraryException("Model '$id' isn't ready: $why")
    class Checksum(file: String) : ModelLibraryException("$file didn't match its SHA-256; it will be downloaded again")
    class Download(file: String, cause: Throwable) : ModelLibraryException("Couldn't download $file: ${cause.message}", cause)
}
