package top.jinso.tacit.audio

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

class AudioPublicationTest {
    @Test fun usesCurrentSpeakerLabelsAndSampleOffsetsAcrossMidnight() {
        val start = Instant.parse("2026-11-10T14:59:58.750Z").toEpochMilli()
        val clip = JSONObject().put("id", "clip").put("start", start).put("samples", 3 * SAMPLE_RATE)
        val speakers = mapOf(
            "self" to JSONObject().put("me", true).put("name", "旧名字"),
            "named" to JSONObject().put("name", "小周"),
            "unknown" to JSONObject(),
        )
        fun row(speaker: String, samples: Int, text: String) =
            JSONObject().put("speaker", speaker).put("start", samples).put("text", text)
        val rows = listOf(
            row("self", 4_000, "周五交第一版。"),
            row("named", 20_000, "我来核对清单。"),
            row("unknown", 38_400, "我会准备投影。"),
        )

        val publication = requireNotNull(audioPublication(clip, rows, ZoneId.of("Asia/Tokyo")) {
            transcriptSpeakerLabel(speakers[it]) { 3 }
        })
        assertEquals(ZoneOffset.ofHours(9), publication.offset)
        assertEquals(start, publication.start)
        assertEquals(start + 3_000, publication.end)
        assertEquals(
            "[23:59:59] 我：周五交第一版。\n[00:00:00] 小周：我来核对清单。\n[00:00:01] 对方 3：我会准备投影。",
            publication.body,
        )
    }
}
