package top.jinso.tacit

import android.os.Bundle
import android.content.Context
import top.jinso.tacit.i18n.AppLocale
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
import top.jinso.tacit.ui.ProvideUiLocalization

class MainActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) = super.attachBaseContext(AppLocale.wrapLegacy(newBase))

    private val resumed = mutableStateOf(0)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        val app = application as TacitApp
        setContent { ProvideUiLocalization { TacitRoot(app, resumed.value) } }
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
