package top.jinso.tacit.ui

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * Tacit's one motion language, shared with the Mac (Motion.swift) and the site: three tempos, no bounce, nothing
 * decorative. Every animation in the app takes its timing from here.
 *
 * - quick: press release, small icon or text swaps, arrow turns, colour changes.
 * - standard: opening and closing, notices coming and going, loading → content, draft → summary.
 * - page: pushing into a page and coming back, changing the day.
 */
internal object Motion {
    val EmphasizedDecelerate = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    val EmphasizedAccelerate = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)
    val StandardEasing = CubicBezierEasing(0.2f, 0f, 0f, 1f)

    const val QUICK_MS = 150
    const val ENTER_MS = 250
    const val EXIT_MS = 200
    const val PAGE_PUSH_MS = 320
    const val PAGE_RETURN_MS = 260
    const val PAGE_LEAVE_MS = 200

    /** Local reads are usually instant; a loading mark waits this long so fast reads show nothing at all. */
    const val LOADING_DELAY_MS = 300L

    fun <T> quick(): FiniteAnimationSpec<T> = tween(QUICK_MS, easing = StandardEasing)

    /** Something appearing or opening. */
    fun <T> enter(): FiniteAnimationSpec<T> = tween(ENTER_MS, easing = EmphasizedDecelerate)

    /** Something leaving or closing; a fifth quicker than it came. */
    fun <T> exit(): FiniteAnimationSpec<T> = tween(EXIT_MS, easing = EmphasizedAccelerate)

    /** Rows making room in a list: critically damped, never overshoots. */
    val place: FiniteAnimationSpec<IntOffset> =
        spring(Spring.DampingRatioNoBouncy, 450f, IntOffset.VisibilityThreshold)

    fun <T> pagePush(): FiniteAnimationSpec<T> = tween(PAGE_PUSH_MS, easing = EmphasizedDecelerate)
    fun <T> pageReturn(): FiniteAnimationSpec<T> = tween(PAGE_RETURN_MS, easing = EmphasizedDecelerate)
    fun <T> pageLeave(): FiniteAnimationSpec<T> = tween(PAGE_LEAVE_MS, easing = EmphasizedAccelerate)

    /** Follows a value polled every 250 ms (download progress) so the bar moves instead of stepping. */
    fun <T> polled(): FiniteAnimationSpec<T> = tween(ENTER_MS, easing = LinearEasing)
}

/**
 * True when the system's animator duration scale is 0 ("Remove animations"). Compose already drops durations to
 * zero then; Tacit additionally leaves out every slide and turn so that only fades or instant cuts remain.
 */
internal val LocalReduceMotion = compositionLocalOf { false }

@Composable
internal fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.applicationContext.contentResolver
    fun read() = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    var reduce by remember(resolver) { mutableStateOf(read()) }
    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { reduce = read() }
        }
        resolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return reduce
}

private fun fadeOnly() = ContentTransform(fadeIn(Motion.enter()), fadeOut(Motion.exit()), sizeTransform = null)

/** Same depth (or reduced motion) just fades; deeper pushes in from the right, back slides the top page away. */
internal fun pageTransform(from: Int, to: Int, reduce: Boolean): ContentTransform = when {
    reduce || from == to -> fadeOnly()
    to > from -> ContentTransform(
        slideInHorizontally(Motion.pagePush()) { it * 16 / 100 } + fadeIn(Motion.pagePush()),
        slideOutHorizontally(Motion.pageLeave()) { -it * 6 / 100 } + fadeOut(Motion.pageLeave()),
        targetContentZIndex = 1f, sizeTransform = null,
    )
    // The page being left stays on top and slides off, uncovering the one beneath.
    else -> ContentTransform(
        slideInHorizontally(Motion.pageReturn()) { -it * 6 / 100 } + fadeIn(Motion.pageReturn()),
        slideOutHorizontally(Motion.pageLeave()) { it * 16 / 100 } + fadeOut(Motion.pageLeave()),
        targetContentZIndex = -1f, sizeTransform = null,
    )
}

/** A later day comes in from the right, an earlier one from the left; the outgoing day eases the other way. */
internal fun dayTransform(later: Boolean, shiftIn: Int, shiftOut: Int, reduce: Boolean): ContentTransform {
    if (reduce) return fadeOnly()
    val sign = if (later) 1 else -1
    return ContentTransform(
        slideInHorizontally(Motion.pagePush()) { sign * shiftIn } + fadeIn(Motion.pagePush()),
        slideOutHorizontally(Motion.pageLeave()) { -sign * shiftOut } + fadeOut(Motion.pageLeave()),
        sizeTransform = null,
    )
}

/** Content that opens below its control: fades in while the space below makes room, and the reverse on close. */
@Composable
internal fun Reveal(visible: Boolean, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val reduce = LocalReduceMotion.current
    AnimatedVisibility(
        visible, modifier,
        enter = if (reduce) fadeIn(Motion.enter()) else fadeIn(Motion.enter()) + expandVertically(Motion.enter(), Alignment.Top),
        exit = if (reduce) fadeOut(Motion.exit()) else fadeOut(Motion.exit()) + shrinkVertically(Motion.exit(), Alignment.Top),
        label = "reveal",
    ) { Column(content = content) }
}

/** Something that appears in place without moving anything else (a button at the end of a row). */
@Composable
internal fun FadeVisibility(visible: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    AnimatedVisibility(visible, modifier, enter = fadeIn(Motion.enter()), exit = fadeOut(Motion.exit()), label = "fade") {
        content()
    }
}

/** Swaps one piece of content for the next in place, with the height following smoothly. */
@Composable
internal fun <T> CrossSwap(target: T, modifier: Modifier = Modifier, content: @Composable (T) -> Unit) {
    AnimatedContent(
        target, modifier,
        transitionSpec = {
            ContentTransform(fadeIn(Motion.enter()), fadeOut(Motion.exit()),
                sizeTransform = SizeTransform { _, _ -> Motion.enter<IntSize>() })
        },
        label = "swap",
    ) { content(it) }
}

/** Loading → content as a cross-fade; the loading side is usually invisible because [DelayedAppearance] waits. */
@Composable
internal fun LoadCrossfade(loading: Boolean, modifier: Modifier = Modifier, content: @Composable (loading: Boolean) -> Unit) {
    Crossfade(loading, modifier, animationSpec = Motion.enter(), label = "load", content = content)
}

/** Fades its content in only once a wait is noticeable, so quick local reads flash nothing. */
@Composable
internal fun DelayedAppearance(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(Motion.LOADING_DELAY_MS)
        shown = true
    }
    val alpha by animateFloatAsState(if (shown) 1f else 0f, Motion.enter(), label = "delayed")
    Box(modifier.graphicsLayer { this.alpha = alpha }) { content() }
}

/** The one expand arrow: a single chevron that turns half a circle, so it reads as the same control opening. */
@Composable
internal fun ExpandChevron(expanded: Boolean, tint: Color, modifier: Modifier = Modifier.size(16.dp)) {
    val reduce = LocalReduceMotion.current
    val turn by animateFloatAsState(
        if (expanded) 180f else 0f, if (reduce) snap() else Motion.quick(), label = "chevron",
    )
    Icon(Icons.Outlined.ExpandMore, null, modifier.graphicsLayer { rotationZ = turn }, tint = tint)
}

/**
 * The last non-null value, so content that is animating out still has something to show after its state has
 * already moved on (a closing error line, a page being left).
 */
@Composable
internal fun <T : Any> rememberLatest(value: T?): T? {
    val holder = remember { arrayOfNulls<Any>(1) }
    if (value != null) holder[0] = value
    @Suppress("UNCHECKED_CAST")
    return holder[0] as T?
}
