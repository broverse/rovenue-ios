//  FunnelStoreBusy.swift — the busy state a presented funnel wears while a
//  purchase or restore it asked for runs (plan 2026-11-16 D2).
//
//  The control that was tapped spins; every other actionable control dims
//  and is disabled to assistive tech; the page takes no touch. Small on
//  purpose: one path, one flag, one percent — it rides the environment of
//  every page layer, so it must stay cheap to compare.

import SwiftUI

/// A purchase or restore is running: which control asked for it (its
/// action path — `cta`, `el.<blockId>`, `opt.<value>`), and how far the
/// rest dims.
struct FunnelStoreBusy: Equatable {
    /// The tapped control's action path; empty when no tap is behind the
    /// purchase, so nothing spins and everything dims.
    let actionPath: String
    let isRestore: Bool
    /// The presentation token `busyDimPercent`: every other control's opacity.
    let dimPercent: UInt32

    func button(_ actionPath: String) -> FunnelButtonBusy {
        !actionPath.isEmpty && actionPath == self.actionPath ? .spinning : .dimmed
    }

    /// `dimPercent` as an opacity.
    var dimOpacity: Double { Double(dimPercent) / FunnelStoreBusyFormat.percent }
}

/// How one button draws while the funnel is busy.
enum FunnelButtonBusy: Equatable {
    /// Not busy: drawn as it always is.
    case none
    /// The control the visitor tapped: its label gives way to a spinner
    /// (chromed) or gains one beside it (chromeless).
    case spinning
    /// Any other control: dimmed and disabled.
    case dimmed
}

extension Optional where Wrapped == FunnelStoreBusy {
    func button(_ actionPath: String) -> FunnelButtonBusy {
        map { $0.button(actionPath) } ?? .none
    }
}

enum FunnelStoreBusyFormat {
    static let percent = 100.0
    static let fullOpacity = 1.0
}

private struct FunnelPageCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FunnelStoreBusyKey: EnvironmentKey {
    static let defaultValue: FunnelStoreBusy? = nil
}

extension EnvironmentValues {
    /// A presentation's purchase overlay is over the page: the page hides
    /// itself from assistive tech so the overlay is the one element.
    var funnelPageCovered: Bool {
        get { self[FunnelPageCoveredKey.self] }
        set { self[FunnelPageCoveredKey.self] = newValue }
    }

    /// Installed per page layer by `FunnelDriverView` from
    /// `FunnelDriver.storeBusy`; nil while nothing is being bought (and
    /// always in an embedded funnel, which does not track it).
    var funnelStoreBusy: FunnelStoreBusy? {
        get { self[FunnelStoreBusyKey.self] }
        set { self[FunnelStoreBusyKey.self] = newValue }
    }
}

/// A leaf control that is not a button (an option list, a field, the
/// progress back control): dimmed and disabled while busy, like the
/// package list.
struct FunnelStoreDimmedControl: ViewModifier {
    @Environment(\.funnelStoreBusy) private var storeBusy

    func body(content: Content) -> some View {
        content.funnelStoreDimmed(storeBusy)
    }
}

/// A container whose own controls (a carousel's arrows and swipe, an
/// accordion's headers) must not act while busy: disabled, so assistive tech
/// reads them unavailable. Not dimmed as a whole — its arrows, indicator and
/// headers dim themselves (`FunnelStoreDimmedControl`), as do the buttons
/// inside, and a purchase button inside may be the one spinning.
struct FunnelStoreDisabledContainer: ViewModifier {
    @Environment(\.funnelStoreBusy) private var storeBusy

    func body(content: Content) -> some View {
        content.disabled(storeBusy != nil)
    }
}

/// `.plain`, except while busy: SwiftUI's plain style also greys a disabled
/// label, which on a control that dims itself (`FunnelStoreDimmedControl`)
/// would draw it at far less than `busyDimPercent`. While busy the label is
/// drawn as is, so the busy dim is its only disabled look; the button, its
/// trait and its disabled state stay.
struct FunnelStorePlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FunnelStorePlainButton(configuration: configuration)
    }
}

private struct FunnelStorePlainButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\.funnelStoreBusy) private var storeBusy

    var body: some View {
        if storeBusy == nil {
            Button(configuration).buttonStyle(.plain)
        } else {
            Button(configuration).buttonStyle(FunnelBareButtonStyle())
        }
    }
}

/// The label alone: no pressed or disabled look.
private struct FunnelBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension View {
    /// A dimmed control: `dimPercent` opacity, and disabled, so assistive
    /// tech reads it as unavailable and it runs nothing. No branch: the
    /// control keeps its identity (and its state) as the busy state comes
    /// and goes.
    func funnelStoreDimmed(_ busy: FunnelStoreBusy?) -> some View {
        opacity(busy?.dimOpacity ?? FunnelStoreBusyFormat.fullOpacity).disabled(busy != nil)
    }
}
