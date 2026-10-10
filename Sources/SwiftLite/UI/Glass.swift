import AppKit
import SwiftUI

/// Liquid Glass on macOS 26 and later, the closest material before it. Everything floating over the
/// conversation (the composer, bars, round buttons, date capsules) goes through here, so the look stays
/// consistent and older systems keep working.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else if let tint {
            background(tint.opacity(0.8), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.5), lineWidth: 0.5))
        }
    }

    /// Glass pieces close to each other blend like drops (macOS 26); a plain group before.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// The transcript fades softly under the floating composer and bars instead of being cut by a line.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }
}

extension View {
    /// Put on the content of a scroll view to remove its scroll bars for good. `scrollIndicators(.hidden)` is
    /// ignored when the Mac is set to always show scroll bars, and a grey rail under a row of chips is the result.
    func hidingEnclosingScrollBars() -> some View {
        background(ScrollBarsOff())
    }
}

private struct ScrollBarsOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollBarsOffView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? ScrollBarsOffView)?.apply() }
}

/// SwiftUI sets the scroll bars of its scroll views again on its own schedule, so this view puts them back
/// off whenever it is attached or laid out, rather than once.
private final class ScrollBarsOffView: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }

    func apply() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
    }
}

/// Plain buttons give no sign that they were hit. Apple's own icon buttons dim a little while pressed.
struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

/// A round glass button for the corner of the conversation ("вниз", "@").
struct GlassCircleLabel<Content: View>: View {
    var diameter: CGFloat = 36
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassSurface(in: Circle(), interactive: true)
    }
}
