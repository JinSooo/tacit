package top.jinso.tacit.sync

import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import org.junit.Assert.assertEquals
import org.junit.Test

class PairingDeviceNameTest {
    private val chinese = TestStrings(AppLang.ZH)

    @Test fun englishFallbackUsesTheSameDeviceNameRules() {
        val english = TestStrings(AppLang.EN)
        assertEquals("Xiaomi phone", pairingDeviceName("ABC123", "abc123", "Xiaomi", english))
        assertEquals("Android phone", pairingDeviceName(null, null, null, english))
        assertEquals("通勤用手机", pairingDeviceName("通勤用手机", "abc123", "Xiaomi", english))
    }

    @Test fun keepsTheNameTheUserSet() {
        assertEquals("通勤用手机", pairingDeviceName(" 通勤用手机 ", "ABC123", "Xiaomi", chinese))
    }

    @Test fun fallsBackWhenTheSystemNameIsOnlyTheModelCode() {
        assertEquals("Xiaomi 手机", pairingDeviceName(" ABC123 ", "abc123", " Xiaomi ", chinese))
    }

    @Test fun handlesDevicesWithoutABrandOrCustomName() {
        assertEquals("Android 手机", pairingDeviceName(null, "ABC123", "unknown", chinese))
        assertEquals("Android 手机", pairingDeviceName(" ", null, null, chinese))
    }
}
