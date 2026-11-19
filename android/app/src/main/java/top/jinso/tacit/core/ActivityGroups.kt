package top.jinso.tacit.core

import top.jinso.tacit.sources.Sources
import java.time.Instant
import java.time.ZoneId

data class ActivityGroup(val records:List<HistoryRecord>) {
    val first get()=records.first()
}
fun groupActivities(records:List<HistoryRecord>, conversations:Map<String,String> = emptyMap()):List<ActivityGroup> {
    val groups=mutableListOf<MutableList<HistoryRecord>>()
    val audioGroups=mutableMapOf<String,MutableList<HistoryRecord>>()
    for(record in records) {
        if(record.source==Sources.AUDIO && record.corrects==null) {
            val conversation=conversations[record.id]
            val key=conversation?.let { it+":"+record.sensitivity }
            val group=key?.let { audioGroups[it] }
            if(group!=null) group.add(record) else {
                val created=mutableListOf(record); groups.add(created)
                if(key!=null)audioGroups[key]=created
            }
            continue
        }
        val current=groups.lastOrNull();val previous=current?.lastOrNull()
        val sameDay=previous!=null&&Instant.ofEpochMilli(previous.start).atZone(ZoneId.systemDefault()).toLocalDate()==Instant.ofEpochMilli(record.start).atZone(ZoneId.systemDefault()).toLocalDate()
        val gap=previous?.let{it.start-(record.end?:record.start)}?:Long.MAX_VALUE
        val canGroup=previous!=null&&sameDay&&previous.source==record.source&&previous.app==record.app&&previous.sensitivity==record.sensitivity&&previous.corrects==null&&record.corrects==null&&record.source in setOf(Sources.USAGE,"android.screen",Sources.NOTIFICATION)&&gap<=600000&& (record.source!=Sources.NOTIFICATION||(record.app!=null&&record.title==previous.title))
        if(canGroup)current!!.add(record)else groups.add(mutableListOf(record))
    }
    return groups.map{ActivityGroup(it.toList())}
}
