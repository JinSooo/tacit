package top.jinso.tacit.core

private val transcriptClockPrefix = Regex("^\\[\\d{2}:\\d{2}:\\d{2}\\]\\s*")

/** Display-only cleanup within one <=30s record. Original text stays available verbatim. */
fun readableTranscript(body: String): String {
    val filler = Regex("(?i)(?:嗯|啊|呃|额|噢|哦|uh|um|hmm)+")
    val turns = mutableListOf<Pair<String,String>>()
    for (line in body.lineSequence()) {
        val split=line.indexOf('：')
        if(split<=0) { if(line.isNotBlank())turns+= "" to line.trim(); continue }
        val speaker = line.substring(0, split).trim().replaceFirst(transcriptClockPrefix, "")
        val text=line.substring(split+1).trim()
        val compact=text.replace(Regex("[\\s\\p{P}\\p{S}]"),"")
        if(text.isBlank()||filler.matches(compact))continue
        val previous=turns.lastOrNull()
        if(previous?.first==speaker) {
            val separator=if(previous.second.lastOrNull()?.let{it in "。！？!?…,，、；;：:"}==true) "" else "，"
            turns[turns.lastIndex]=speaker to previous.second+separator+text
        } else turns+=speaker to text
    }
    return turns.joinToString("\n\n"){(speaker,text)->if(speaker.isBlank())text else "$speaker：$text"}
}
