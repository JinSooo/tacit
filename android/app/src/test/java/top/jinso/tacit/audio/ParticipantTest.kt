package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class ParticipantTest {
    /** A unit vector at [degrees] from the x axis; cosine between two of them is cos(difference). */
    private fun at(degrees: Double) = Math.toRadians(degrees).let { floatArrayOf(cos(it).toFloat(), sin(it).toFloat()) }

    // Reported case (2026-11-22): a 3-hour call showed 226 "对方" because every short span became its own voice.
    @Test fun shortFragmentJoinsTheLongVoiceItResembles() {
        val long = listOf(Participant(1, at(0.0), 120.0), Participant(2, at(90.0), 40.0))
        assertEquals(2, joinParticipant(long, at(70.0), 1.5)) // cos 0.94 to #2 beats 0.34 to #1
        assertEquals(1, joinParticipant(long, at(20.0), 1.5))
    }

    @Test fun unlikeVoicesStaySeparate() {
        val long = listOf(Participant(1, at(0.0), 120.0))
        assertNull(joinParticipant(long, at(80.0), 1.5)) // cos 0.17 < attach 0.3
        // Short participants never absorb others: their centers are too noisy to anchor anyone.
        assertNull(joinParticipant(listOf(Participant(1, at(0.0), 2.0)), at(10.0), 1.5))
    }

    @Test fun longVoicesNeedTheStricterJoin() {
        val long = listOf(Participant(1, at(0.0), 120.0))
        assertNull(joinParticipant(long, at(65.0), 30.0)) // cos 0.42: enough to attach a fragment, not to merge two voices
        assertEquals(1, joinParticipant(long, at(55.0), 30.0)) // cos 0.57 >= join 0.5
    }
}
