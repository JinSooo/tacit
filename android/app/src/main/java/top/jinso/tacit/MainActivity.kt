package top.jinso.tacit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import top.jinso.tacit.ui.TacitRoot

class MainActivity : ComponentActivity() {
    private val resumed = mutableStateOf(0)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        setContent { TacitRoot(application as TacitApp, resumed.value) }
    }
    override fun onResume() {
        super.onResume()
        resumed.value++
        top.jinso.tacit.sync.SyncWorker.enqueue(this)
    }
}
