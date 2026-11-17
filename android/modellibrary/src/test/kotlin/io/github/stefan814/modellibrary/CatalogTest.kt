package io.github.stefan814.modellibrary

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class CatalogTest {
    private val legacyFile = File("src/main/assets/${Handles.LEGACY_ASSET}")
    private val handles = Handles.parseLegacy(legacyFile.readText())
    private val vad = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
    private val json = """{"models": [
        {"id": "my-vad", "files": [{"name": "detector.onnx", "size": 643854, "sha256": "$vad", "urls": ["https://example.com/v"]}]},
        {"id": "other", "title": "Other", "capability": "x", "license": "MIT",
         "files": [{"name": "a.bin", "size": 5, "sha256": "${"ab".repeat(32)}", "urls": ["https://example.com/a"]}]}
    ]}"""

    /** Phones hold these blobs and older apps look for them under exactly these names: the table must never change. */
    @Test fun `v1 handle table is frozen`() {
        val sha = MessageDigest.getInstance("SHA-256").digest(legacyFile.readBytes()).joinToString("") { "%02x".format(it) }
        assertEquals("96feede8f0b14b2e3b2e5674c213b0ffdae7270de852f7be0b6e30e68a5e6611", sha)
    }

    @Test fun `files the library listed before keep their v1 names, whatever the app calls them`() {
        assertEquals(listOf(Handles.Name("Garden model silero-vad-v5 (vad.onnx)", "garden/v1/silero-vad-v5/vad.onnx")), handles.names(vad))
        val m = Catalog.parse(json)["my-vad"]
        assertEquals("garden/v1/silero-vad-v5/vad.onnx", handles.names(m.files[0].sha256).first().tag)
        assertEquals("modellibrary/my-vad/detector.onnx", Handles.assetPath(m, m.files[0]))
    }

    @Test fun `any other file is named by its hash alone`() {
        val sha = "ab".repeat(32)
        assertEquals(listOf(Handles.Name("Garden shared model file", "garden/v2/$sha")), handles.names(sha))
    }

    @Test fun `every name fits the system limits`() {
        for (sha in listOf(vad, "ab".repeat(32)) + Regex("\"([0-9a-f]{64})\"").findAll(legacyFile.readText()).map { it.groupValues[1] })
            for (n in handles.names(sha)) {
                assertTrue(n.label, n.label.length <= Handles.MAX_LABEL)
                assertTrue(n.tag, n.tag.length <= Handles.MAX_TAG)
            }
    }

    @Test fun `parses with or without a format, metadata optional`() {
        val c = Catalog.parse(json)
        assertEquals(listOf("my-vad", "other"), c.models.map { it.id })
        assertEquals("my-vad", c["my-vad"].title)
        assertEquals("Other", c["other"].title)
        assertEquals(listOf("other"), c.forCapability("x").map { it.id })
        assertEquals(2, Catalog.parse(json.replaceFirst("{", "{\"format\": 1, ")).models.size)
        assertEquals(2, Catalog.parse(json.replaceFirst("{", "{\"scheme\": 1, ")).models.size)
    }

    @Test fun `built in code`() {
        val c = Catalog(listOf(Model("x", listOf(ModelFile("f.bin", 1, "cd".repeat(32), listOf("https://e.com/f"))))))
        assertEquals(1L, c["x"].bytes)
        assertTrue(runCatching { Catalog(listOf(Model("x", emptyList()))) }.isFailure)
    }

    @Test fun `digest round trips`() = assertEquals(vad, ModelLibrary.hex(Handles.digest(vad)))

    @Test fun `rejects bad entries`() {
        fun bad(edit: (String) -> String) = runCatching { Catalog.parse(edit(json)) }.isFailure
        assertFalse("the sample is good", bad { it })
        assertTrue("uppercase sha", bad { it.replace("9e2449e1", "9E2449E1") })
        assertTrue("duplicate id", bad { it.replace("\"other\"", "\"my-vad\"") })
        assertTrue("unknown format", bad { it.replaceFirst("{", "{\"format\": 2, ") })
        assertTrue("bad id", bad { it.replace("\"my-vad\"", "\"My VAD\"") })
        assertTrue("id over 48 chars", bad { it.replace("\"other\"", "\"" + "p".repeat(49) + "\"") })
        assertTrue("same file in two models", bad { it.replace("ab".repeat(32), vad) })
        assertFalse("...unless allowed (tests)", runCatching { Catalog.parse(json.replace("ab".repeat(32), vad), allowSameFile = true) }.isFailure)
        assertTrue("bad url", bad { it.replace("https://example.com/a", "ftp://x") })
        assertTrue("unknown model lookup", runCatching { Catalog.parse(json)["nope"] }.isFailure)
    }

    @Test fun `quota rule`() {
        assertTrue(Quota.fits(177_000_000, 300L shl 20))
        assertFalse("Gemma never fits a 128 GB phone's 1%", Quota.fits(2_588_147_712, 1_118L shl 20))
    }
}
