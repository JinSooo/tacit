package top.jinso.tacit.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingDeviceNameTest {
    @Test fun keepsTheNameTheUserSet() {
        assertEquals("通勤用手机", pairingDeviceName(" 通勤用手机 ", "ABC123", "Xiaomi"))
    }

    @Test fun fallsBackWhenTheSystemNameIsOnlyTheModelCode() {
        assertEquals("Xiaomi 手机", pairingDeviceName(" ABC123 ", "abc123", " Xiaomi "))
    }

    @Test fun handlesDevicesWithoutABrandOrCustomName() {
        assertEquals("Android 手机", pairingDeviceName(null, "ABC123", "unknown"))
        assertEquals("Android 手机", pairingDeviceName(" ", null, null))
    }
}
