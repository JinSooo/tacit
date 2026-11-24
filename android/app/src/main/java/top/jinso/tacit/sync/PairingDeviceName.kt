package top.jinso.tacit.sync

internal fun pairingDeviceName(systemName: String?, model: String?, brand: String?): String {
    val custom = systemName?.trim()
    if (!custom.isNullOrEmpty() && !custom.equals(model?.trim(), ignoreCase = true)) return custom.take(200)
    val maker = brand?.trim()?.takeUnless { it.isBlank() || it.equals("unknown", ignoreCase = true) }
    return if (maker == null) "Android 手机" else "${maker.take(197)} 手机"
}
