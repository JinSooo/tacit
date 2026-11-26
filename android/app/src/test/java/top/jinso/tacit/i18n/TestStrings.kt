package top.jinso.tacit.i18n

import org.w3c.dom.Element
import top.jinso.tacit.R
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory

internal fun fixture(path: String): File =
    generateSequence(File(".").absoluteFile.normalize()) { it.parentFile }
        .map { File(it, path) }.first { it.isFile }

/** Read the actual Android resource files on the JVM, without mocking a Context. */
internal class TestStrings(private val lang: AppLang) : UiStrings {
    private val directory = if (lang == AppLang.ZH) "values-zh" else "values"
    private val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        .parse(fixture("android/app/src/main/res/$directory/strings.xml"))
    private val names = R.string::class.java.fields.associate { it.getInt(null) to it.name }
    private val pluralNames = R.plurals::class.java.fields.associate { it.getInt(null) to it.name }

    private fun resource(tag: String, name: String): Element {
        val nodes = document.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }.first { it.getAttribute("name") == name }
    }

    private fun format(pattern: String, args: Array<out Any>): String {
        val value = pattern.replace("\\'", "'").replace("\\\"", "\"")
        return if (args.isEmpty()) value else String.format(Locale.US, value, *args)
    }

    override fun text(id: Int, vararg args: Any) = format(resource("string", names.getValue(id)).textContent, args)

    override fun quantity(id: Int, count: Int, vararg args: Any): String {
        val group = resource("plurals", pluralNames.getValue(id)).getElementsByTagName("item")
        val quantity = if (lang == AppLang.EN && count == 1) "one" else "other"
        val item = (0 until group.length).map { group.item(it) as Element }.first { it.getAttribute("quantity") == quantity }
        return format(item.textContent, args)
    }
}
