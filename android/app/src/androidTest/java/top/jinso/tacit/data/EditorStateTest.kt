package top.jinso.tacit.data

import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import top.jinso.tacit.MainActivity
import top.jinso.tacit.ui.EditorDraftModel

@RunWith(AndroidJUnit4::class)
class EditorStateTest {
    @Test fun unsavedTextSurvivesActivityRecreationInMemory() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var original: EditorDraftModel? = null
            scenario.onActivity { activity ->
                original = ViewModelProvider(activity)[EditorDraftModel::class.java].also {
                    it.open("test-draft", "test-title", "unsaved text", true)
                }
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val restored=ViewModelProvider(activity)[EditorDraftModel::class.java]
                assertSame(original,restored)
                assertEquals("unsaved text",restored.body)
                assertTrue(restored.private)
                restored.clear()
            }
        }
    }
}
