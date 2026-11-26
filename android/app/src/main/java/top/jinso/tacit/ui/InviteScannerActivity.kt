package top.jinso.tacit.ui

import android.content.Context
import com.journeyapps.barcodescanner.CaptureActivity
import top.jinso.tacit.i18n.AppLocale

/** Keeps the scanner's own dialogs in Tacit's language, including on API 28–32. */
class InviteScannerActivity : CaptureActivity() {
    override fun attachBaseContext(newBase: Context) =
        super.attachBaseContext(AppLocale.localizedContext(newBase))
}
