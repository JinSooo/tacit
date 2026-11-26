package top.jinso.tacit.sync

import top.jinso.tacit.R
import top.jinso.tacit.i18n.UiStrings

internal fun pairingDeviceName(systemName: String?, model: String?, brand: String?, strings: UiStrings): String {
    val custom = systemName?.trim()
    if (!custom.isNullOrEmpty() && !custom.equals(model?.trim(), ignoreCase = true)) return custom.take(200)
    val maker = brand?.trim()?.takeUnless { it.isBlank() || it.equals("unknown", ignoreCase = true) }
    return if (maker == null) strings.text(R.string.android_phone)
        else strings.text(R.string.maker_phone, maker.take(200 - strings.text(R.string.maker_phone, "").length))
}
