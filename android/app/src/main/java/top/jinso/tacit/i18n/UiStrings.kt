package top.jinso.tacit.i18n

internal interface UiStrings {
    fun text(id: Int, vararg args: Any): String
    fun quantity(id: Int, count: Int, vararg args: Any): String
}

internal data class UiMessage(val label: Int, val argument: String? = null) {
    fun resolve(strings: UiStrings): String =
        if (argument == null) strings.text(label) else strings.text(label, argument)
}
