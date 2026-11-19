package top.jinso.tacit.core

import org.junit.Assert.*
import org.junit.Test

class SecretsTest {
    @Test fun filtersKnownSecretsInsideProseAndURLs() {
        val value="sk-"+"abcdefgh1234567890ABCDEFGH"
        val result=Secrets.redact("示例 $value https://user:secret@localhost Bearer abcdefgh1234567890")
        assertFalse(result.text.contains(value));assertFalse(result.text.contains("user:secret@"));assertEquals(3,result.count)
    }
    @Test fun preservesOrdinaryIdentifiersAndChineseNotes() {
        val prose="今天完成 android.source_ref，版本 1.2.3，继续记录。"
        assertEquals(prose,Secrets.redact(prose).text)
        assertEquals(0,Secrets.redact(prose).count)
    }
    @Test fun filtersMultilinePrivateKeyAndEntropyAssignments() {
        val pem="-----BEGIN PRIVATE KEY-----\nZXhhbXBsZQ==\n-----END PRIVATE KEY-----"
        assertFalse(Secrets.redact(pem).text.contains("ZXhh"))
        assertTrue(Secrets.redact("api_key='Ab12Cd34Ef56Gh78Ij90KlMn'").count>0)
    }
    @Test fun partialPrivateKeyIsAlsoRemoved() {
        assertEquals("[已脱敏]",Secrets.redact("-----BEGIN PRIVATE KEY-----\nZXhhbXBsZQ").text)
    }
    @Test fun idsAreValidUniqueAndMonotonic() {
        val values=(0..10000).map{Ids.next()}
        assertEquals(values.size,values.toSet().size)
        assertEquals(values.sorted(),values)
        assertTrue(values.all{it.matches(Regex("[0-9A-HJKMNP-TV-Z]{26}"))})
    }
}
