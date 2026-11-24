package top.jinso.tacit.audio

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A cancelled or superseded read must never start playing when it finally leaves the disk queue. */
internal class SamplePlayback {
    class Request(val speakerId: String)

    private val currentSpeaker = MutableStateFlow<String?>(null)
    val speaker = currentSpeaker.asStateFlow()
    private var active: Request? = null
    private var release: (() -> Unit)? = null

    @Synchronized fun toggle(id: String): Request? {
        val alreadyPlaying = active?.speakerId == id
        stop()
        if (alreadyPlaying) return null
        return Request(id).also { active = it; currentSpeaker.value = id }
    }

    @Synchronized fun play(request: Request, start: () -> Unit, close: () -> Unit) {
        if (active !== request) {
            close()
            return
        }
        release = close
        start()
    }

    @Synchronized fun finish(request: Request) {
        if (active === request) stop()
    }

    @Synchronized fun stop() {
        active = null
        currentSpeaker.value = null
        val close = release
        release = null
        close?.invoke()
    }
}
