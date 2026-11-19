package top.jinso.tacit

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import top.jinso.tacit.ui.TacitRoot

class MainActivity : ComponentActivity() {
    private val shared = mutableStateOf<String?>(null)
    private val quickNote = mutableStateOf(0)
    private val resumed = mutableStateOf(0)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        if (savedInstanceState == null) receive(intent)
        setContent { TacitRoot(application as TacitApp, shared.value, resumed.value, quickNote.value) { shared.value = null } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); receive(intent) }
    override fun onResume() { super.onResume(); resumed.value++ }
    private fun receive(intent: Intent?) {
        if (intent?.action == "top.jinso.tacit.WRITE") quickNote.value++
        if(intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") shared.value = intent.getStringExtra(Intent.EXTRA_TEXT)?.take(200000)
    }
}
