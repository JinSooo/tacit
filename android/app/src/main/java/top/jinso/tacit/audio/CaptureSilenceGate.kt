package top.jinso.tacit.audio

/** A transition during a blocking read invalidates that block and its unfinished clip. */
internal class CaptureSilenceGate {
    @Volatile var silenced = false
        private set
    @Volatile var revision = 0L
        private set
    @Synchronized fun update(value: Boolean) {
        if (silenced != value) { silenced = value; revision++ }
    }
    fun drop(previousRevision: Long) = silenced || revision != previousRevision
}
