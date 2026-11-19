package top.jinso.tacit.core

import org.junit.Assert.*
import org.junit.Test

class ActivityGroupsTest {
    private fun row(id:String,source:String,time:Long)=HistoryRecord(id,source,"title","body",time,time+1000,null,"normal",null,0)
    @Test fun conversationsGroupThroughInterveningActivitiesButNeverByTimeAlone() {
        val records=listOf(row("a","android.audio",3000),row("n","android.notification",2500),row("b","android.audio",2000),row("c","android.audio",1000))
        val groups=groupActivities(records,mapOf("a" to "scene1","b" to "scene1","c" to "scene2"))
        assertEquals(listOf(listOf("a","b"),listOf("n"),listOf("c")),groups.map{it.records.map{r->r.id}})
        assertEquals(4,groupActivities(records).size)
    }
    @Test fun unrelatedProviderEventsAreNotGroupedJustBecauseTheirAppIsNull() {
        for(source in listOf("android.sms","android.calls","android.files","android.calendar","android.media","android.location")) {
            assertEquals(2,groupActivities(listOf(row("a",source,2000),row("b",source,1000))).size)
        }
    }
    @Test fun privateAudioDoesNotMergeIntoNormalConversationPreview() {
        val normal=row("a","android.audio",3000)
        val private=row("b","android.audio",2000).copy(sensitivity="private")
        assertEquals(2,groupActivities(listOf(normal,private),mapOf("a" to "same","b" to "same")).size)
    }
}
