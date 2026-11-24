import AppKit
import SwiftUI

/// 全项目的动效语言。动效只用来交代“发生了什么”：东西从哪来、到哪去、和什么有关。
/// 只有三档节奏，同一类变化只用其中一档；曲线都是不回弹的临界阻尼弹簧，动画进行中再次操作会从当前速度接上。
/// 打开“减少动态效果”后，位移、旋转、缩放一律退化成短淡入淡出，数字不滚动。
enum Motion {
  /// 悬停、松手、图标和文字小换、数字滚动。用户反复做的操作都在这一档。
  static var quick: Animation { reduced ? fade : .smooth(duration: 0.15) }
  // 减少动态效果时，展开、换天、面板这类会挪动位置的变化直接切换；只有悬停、颜色、数字这类原地变化保留短淡换。
  /// 展开收起、内容出现消失、加载变内容、选中块滑动、提示行进出。
  static var standard: Animation? { reduced ? nil : .smooth(duration: 0.26) }
  /// 换天、侧栏、详情栏、面板这类整块换位。
  static var page: Animation? { reduced ? nil : .smooth(duration: 0.32) }
  /// “减少动态效果”下唯一的动画：短淡入淡出，不带位移。
  static let fade = Animation.easeInOut(duration: 0.15)

  /// 系统设置 › 辅助功能 › 显示 › 减少动态效果。
  static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// 加载超过这么久才露出“正在读取”，本机读取通常更快，免得转圈一闪而过。
  static let loadingDelay: Duration = .milliseconds(350)

  /// 包一层 withAnimation，统一从这里走。
  static func animate<Result>(_ animation: Animation? = standard, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(animation, body)
  }
}

extension AnyTransition {
  /// 展开出来的内容：下面的内容顺滑让位，它自己原地淡入；不位移，免得盖到上面那行字。
  static var reveal: AnyTransition { .opacity }
  /// 页首提示行这类插进来的整行：淡入并从上方轻落 4pt，离开时只淡出。
  static var notice: AnyTransition {
    Motion.reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
  }
  /// 换天的内容：新的一天淡入，旧的一天先快速淡掉（0.12 秒），两天的文字不在同一处叠太久。
  /// 方向交给日期栏的数字滚动；整块位移会让每一行的悬停区域逐帧重算，实测 120Hz 下几乎帧帧超时。
  static var dayChange: AnyTransition {
    .asymmetric(insertion: .opacity, removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12)))
  }
}

extension View {
  /// 悬停状态：进出都用 quick 淡入淡出，鼠标快速划过时从当前位置接上。
  func hoverState(_ hovering: Binding<Bool>, enabled: Bool = true) -> some View {
    onHover { inside in
      guard enabled || !inside else { return }
      withAnimation(Motion.quick) { hovering.wrappedValue = inside }
    }
  }

  /// 按下反馈：按下即时（不拖手），松手淡出。
  func pressFeedback(_ pressed: Bool) -> some View {
    animation(pressed ? nil : Motion.quick, value: pressed)
  }

  /// 数字变化时逐位滚动（等宽数字，不抖宽度）。
  func rollingNumber<V: Equatable>(_ value: V) -> some View {
    monospacedDigit()
      .contentTransition(Motion.reduced ? .opacity : .numericText())
      .animation(Motion.quick, value: value)
  }

  /// 内容整体换了一版（例如“复制”→“已复制”、加载 → 内容）：交叉淡入淡出。
  func crossfade<V: Equatable>(on value: V, _ curve: Animation? = Motion.standard) -> some View {
    animation(curve, value: value)
  }
}

/// 展开箭头：全项目只用这一个，朝下的箭头转 180° 表示收起，不换图。
struct DisclosureChevron: View {
  let expanded: Bool
  var size: CGFloat = 11
  /// 侧栏式“向右 → 向下”的箭头。
  var sideways = false

  var body: some View {
    PhIcon(sideways ? "caret-right" : "caret-down", size: size)
      .rotationEffect(.degrees(expanded ? (sideways ? 90 : 180) : 0))
      .animation(Motion.standard, value: expanded)
      .accessibilityHidden(true)
  }
}

/// 加载中：等一小会儿还没好才淡入转圈，读得快时什么都不闪。
struct DelayedProgress: View {
  var size: ControlSize = .small
  var label = "正在读取"
  @State private var visible = false

  var body: some View {
    ProgressView().controlSize(size)
      .opacity(visible ? 1 : 0)
      .accessibilityLabel(label)
      .task {
        try? await Task.sleep(for: Motion.loadingDelay)
        withAnimation(Motion.quick) { visible = true }
      }
  }
}
