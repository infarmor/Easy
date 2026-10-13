import AppKit
import SwiftUI

/// The app's motion, in one place. Springs, because they start from wherever a view is on screen and so can
/// be interrupted and redirected at any moment; critically damped unless something physical (a reaction
/// landing, a button let go) earns a little bounce. With Reduce Motion on, movement becomes a short fade.
enum Motion {
    /// Hover, highlights, small state flips.
    static let quick = Animation.spring(duration: 0.18, bounce: 0)
    /// Bars, rows and panels coming and going.
    static let standard = Animation.spring(duration: 0.3, bounce: 0)
    /// Sheets and larger rearrangements.
    static let gentle = Animation.spring(duration: 0.42, bounce: 0)
    /// Something that lands: a badge appearing, a reaction, a button released.
    static let lively = Animation.spring(duration: 0.32, bounce: 0.22)
    /// What Reduce Motion gets instead: no travel, no overshoot, only a fade.
    static let reduced = Animation.easeInOut(duration: 0.15)

    /// For `withAnimation` outside a view, where the environment cannot be read.
    static func respecting(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? reduced : animation
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(animation.map { reduceMotion ? Motion.reduced : $0 }, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that turns into a plain fade under Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// Small things arriving in place: a badge, a mark, a count.
    static var pop: AnyTransition { .scale(scale: 0.6).combined(with: .opacity) }
}
