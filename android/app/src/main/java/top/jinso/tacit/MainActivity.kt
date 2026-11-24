package top.jinso.tacit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import top.jinso.tacit.ui.TacitRoot

class MainActivity : ComponentActivity() {
    private val resumed = mutableStateOf(0)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        val app = application as TacitApp
        setContent { TacitRoot(app, resumed.value) }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                app.sync.refreshTimeline(foreground = true)
                while (true) {
                    delay(30_000)
                    app.sync.refreshTimeline()
                }
            }
        }
    }
    override fun onResume() {
        super.onResume()
        resumed.value++
    }
}
