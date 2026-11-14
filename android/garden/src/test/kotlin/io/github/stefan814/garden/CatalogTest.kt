package io.github.stefan814.garden

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CatalogTest {
    private val json = File("../../catalog/garden-catalog.json").readText()
    private val catalog = Catalog.parse(json)

    @Test fun `bundled catalog parses and validates`() {
        assertEquals(Handles.SCHEME, catalog.scheme)
        assertEquals(listOf("parakeet-tdt-110m-en-int8", "silero-vad-v5", "titanet-small-en", "pyannote-seg-3.0"), catalog.models.map { it.id })
    }

    /** These are the exact files Earshot and Skald pin today; if they drift, sharing silently stops working. */
    @Test fun `hashes match what the apps already pin`() {
        assertEquals("0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657", catalog["parakeet-tdt-110m-en-int8"].file("encoder.int8.onnx").sha256)
        assertEquals("9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", catalog["silero-vad-v5"].file("vad.onnx").sha256)
        assertEquals("ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e", catalog["titanet-small-en"].file("embed.onnx").sha256)
        assertEquals("220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079", catalog["pyannote-seg-3.0"].file("model.onnx").sha256)
        assertEquals(136_490_421L, catalog["parakeet-tdt-110m-en-int8"].bytes)
    }

    /** Frozen: changing these for a published file creates a duplicate blob on every phone. */
    @Test fun `handle naming is frozen`() {
        val m = catalog["silero-vad-v5"]; val f = m.file("vad.onnx")
        assertEquals("garden/v1/silero-vad-v5/vad.onnx", Handles.tag(m, f))
        assertEquals("Garden model silero-vad-v5 (vad.onnx)", Handles.label(m, f))
        assertEquals("garden/silero-vad-v5/vad.onnx", Handles.assetPath(m, f))
    }

    @Test fun `every handle fits the system limits`() {
        for (m in catalog.models) for (f in m.files) {
            assertTrue(Handles.label(m, f).length <= Handles.MAX_LABEL)
            assertTrue(Handles.tag(m, f).length <= Handles.MAX_TAG)
        }
    }

    @Test fun `digest round trips`() {
        val sha = catalog["silero-vad-v5"].files[0].sha256
        assertEquals(sha, Garden.hex(Handles.digest(sha)))
    }

    @Test fun `rejects bad entries`() {
        fun bad(edit: (String) -> String) = runCatching { Catalog.parse(edit(json)) }.isFailure
        assertTrue("uppercase sha", bad { it.replace("9e2449e1", "9E2449E1") })
        assertTrue("duplicate id", bad { it.replace("\"titanet-small-en\"", "\"silero-vad-v5\"") })
        assertTrue("unknown scheme", bad { it.replace("\"scheme\": 1", "\"scheme\": 2") })
        assertTrue("bad id", bad { it.replace("\"silero-vad-v5\"", "\"Silero VAD\"") })
        assertTrue("id over 48 chars", bad { it.replace("\"pyannote-seg-3.0\"", "\"" + "p".repeat(49) + "\"") })
        assertTrue("long id + long file name blows the 100-char label limit", bad {
            it.replace("\"pyannote-seg-3.0\"", "\"" + "p".repeat(48) + "\"").replace("\"model.onnx\"", "\"" + "m".repeat(43) + ".onnx\"")
        })
        assertTrue("same file in two models", bad { it.replace("ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e", "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6") })
        assertTrue("unknown model lookup", runCatching { catalog["nope"] }.isFailure)
    }

    @Test fun `quota rule`() {
        assertTrue(Quota.fits(177_000_000, 300L shl 20))
        assertFalse("Gemma never fits a 128 GB phone's 1%", Quota.fits(2_588_147_712, 1_118L shl 20))
    }
}
