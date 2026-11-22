package top.jinso.tacit.sources

import android.app.Notification
import androidx.core.app.NotificationCompat

internal const val WECHAT_PACKAGE = "com.tencent.mm"

internal data class ChatPreview(val conversation: String, val sender: String?, val message: String) {
    val body: String get() = sender?.let { "$it：$message" } ?: message
}

internal fun chatPreview(notification: Notification, packageName: String): ChatPreview? {
    if (notification.visibility == Notification.VISIBILITY_SECRET ||
        notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
    val extras = notification.extras ?: return null
    // An inline reply leaves history in the update. WeChat sends the key with a null value on every message,
    // so only real history counts (reported: all 108 WeChat notifications were dropped on the key alone).
    if (extras.getCharSequenceArray(Notification.EXTRA_REMOTE_INPUT_HISTORY)?.isNotEmpty() == true) return null

    if (extras.containsKey(Notification.EXTRA_MESSAGES)) {
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notification) ?: return null
        val latest = style.messages.lastOrNull() ?: return null
        val sender = latest.person?.name?.toString()?.trim()?.take(256)
            ?.takeIf(String::isNotEmpty) ?: return null
        val conversation = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()?.take(256)
            ?.takeIf(String::isNotEmpty) ?: sender
        val message = latest.text?.toString()?.trim()?.take(8_000)?.takeIf(String::isNotEmpty) ?: return null
        return ChatPreview(conversation, sender, message)
    }

    return plainChatPreview(
        packageName, extras.getCharSequence(Notification.EXTRA_TITLE),
        extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE),
        extras.getCharSequence(Notification.EXTRA_TEXT),
    )
}

private val weChatUnreadCount = Regex("^\\[\\d+条]\\s*")
private val weChatSenderPrefix = Regex("^([^:\n：]{1,80})[:：]\\s+(.+)$", RegexOption.DOT_MATCHES_ALL)

internal fun plainChatPreview(
    packageName: String, title: CharSequence?, conversationTitle: CharSequence?, text: CharSequence?,
): ChatPreview? {
    val name = title?.toString()?.trim()?.take(256)?.takeIf(String::isNotEmpty)
    val group = conversationTitle?.toString()?.trim()?.take(256)?.takeIf(String::isNotEmpty)
    val conversation = group ?: name ?: return null
    // WeChat prefixes the unread count ("[3条]") when several messages wait; it is not part of the sender or text.
    val message = text?.toString()?.trim()?.let { if (packageName == WECHAT_PACKAGE) it.replaceFirst(weChatUnreadCount, "") else it }
        ?.take(8_000)?.takeIf(String::isNotEmpty) ?: return null
    val prefixed = if (packageName == WECHAT_PACKAGE && (group == null || group == name)) {
        weChatSenderPrefix.matchEntire(message)
    } else null
    return if (prefixed != null) {
        ChatPreview(conversation, prefixed.groupValues[1].trim(), prefixed.groupValues[2])
    } else {
        ChatPreview(conversation, name?.takeUnless { group == it }, message)
    }
}
