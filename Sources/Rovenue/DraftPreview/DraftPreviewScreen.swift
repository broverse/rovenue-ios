//  DraftPreviewScreen.swift — what the draft-preview presenter draws: the
//  funnel through the SDK's own `RovenueFunnelView`, under a small floating
//  chrome (Close, Restart, the "Draft preview · live" badge) and a
//  collapsible issues banner; the "Can't render this draft" list when the
//  draft fails the shape gate (FM9); the simulated purchase sheet (FM10).
//
//  The chrome is SDK chrome, not funnel drawing: system controls and
//  materials only. Every number the funnel draws with stays the funnel's.

#if os(iOS)
import SwiftUI

struct DraftPreviewScreen: View {
    @ObservedObject var model: DraftPreviewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The chrome sits in the top safe area rather than over the
            // funnel's first block; the funnel's background still runs
            // under it.
            .safeAreaInset(edge: .top, spacing: Metrics.chromeGap) { chrome }
            .overlay(alignment: .bottom) {
                if model.ended { endedBanner }
            }
            .sheet(item: $model.purchaseRequest) { request in
                SimulatedPurchaseSheet(request: request) { model.resolve(request, $0) }
                    // A swipe-down is a cancel: the funnel stays where it is.
                    .onDisappear {
                        if model.purchaseRequest == request { model.resolve(request, .cancel) }
                    }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { alert in
                Button(alert.button) { model.alert = nil }
            } message: { alert in
                Text(alert.message)
            }
        // No identifier on this container: SwiftUI hands a container's
        // identifier down to every child, replacing theirs. The presenter
        // names the hosting view instead.
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.cantRender {
            CantRenderView(title: Copy.cantRenderTitle, detail: Copy.cantRenderDetail, issues: model.issues)
        } else if let error = model.buildError {
            CantRenderView(title: Copy.cantRenderTitle, detail: error, issues: model.issues)
        } else if let outcome = model.outcome {
            OutcomeView(outcome: outcome, onRestart: model.restart, onClose: model.close)
        } else if let driver = model.driver {
            RovenueFunnelView(driver: driver).id(model.generation)
        } else {
            ProgressView()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: Metrics.bannerGap) {
            HStack(spacing: Metrics.chromeSpacing) {
                Button(action: model.close) {
                    Image(systemName: "xmark")
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                }
                .accessibilityLabel(Copy.close)
                .accessibilityIdentifier(DraftPreviewAccessibilityID.close)
                Spacer(minLength: 0)
                Label(Copy.badge, systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Copy.badge)
                    .accessibilityIdentifier(DraftPreviewAccessibilityID.badge)
                Spacer(minLength: 0)
                Button(action: model.restart) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                }
                .disabled(!model.canRestart)
                .accessibilityLabel(Copy.restart)
                .accessibilityIdentifier(DraftPreviewAccessibilityID.restart)
            }
            .padding(.horizontal, Metrics.chromePadding)
            .background(.ultraThinMaterial, in: Capsule())
            if !model.issues.isEmpty, !model.cantRender {
                issuesBanner
            }
        }
        .padding(.horizontal, Metrics.chromeInset)
    }

    private var issuesBanner: some View {
        DisclosureGroup(isExpanded: $model.issuesExpanded) {
            ScrollView {
                IssueList(issues: model.issues)
            }
            .frame(maxHeight: Metrics.issuesMaxHeight)
        } label: {
            Label(Copy.issuesSummary(model.issues.count), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(DraftPreviewAccessibilityID.issues)
        }
        .padding(Metrics.bannerPadding)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.bannerCornerRadius, style: .continuous))
    }

    private var endedBanner: some View {
        Text(Copy.ended)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Metrics.chromePadding)
            .padding(.vertical, Metrics.bannerPadding)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, Metrics.chromeInset)
            .accessibilityIdentifier(DraftPreviewAccessibilityID.ended)
    }
}

/// The issues as a list: what is wrong, then where.
private struct IssueList: View {
    let issues: [DraftPreviewIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: Metrics.pathGap) {
                    Text(issue.message).font(.footnote)
                    Text(issue.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The full-screen refusal: the draft cannot be drawn, and why.
private struct CantRenderView: View {
    let title: String
    let detail: String
    let issues: [DraftPreviewIssue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .accessibilityIdentifier(DraftPreviewAccessibilityID.cantRender)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                IssueList(issues: issues)
            }
            .padding(Metrics.pagePadding)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}

/// Where the funnel ended, with a way back in.
private struct OutcomeView: View {
    let outcome: DraftPreviewModel.Outcome
    let onRestart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Metrics.sectionGap) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(DraftPreviewAccessibilityID.outcome)
            Text(Copy.outcomeDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(Copy.restartFunnel, action: onRestart).buttonStyle(.borderedProminent)
            Button(Copy.closePreview, action: onClose)
        }
        .padding(Metrics.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private var title: String {
        switch outcome {
        case .purchased(let name): return Copy.purchased(name)
        case .restored: return Copy.restored
        case .finished: return Copy.finished
        }
    }
}

private enum Metrics {
    static let chromeGap: CGFloat = 4
    static let bannerGap: CGFloat = 8
    static let chromeSpacing: CGFloat = 8
    static let chromePadding: CGFloat = 12
    static let chromeInset: CGFloat = 16
    static let controlSize: CGFloat = 36
    static let issuesMaxHeight: CGFloat = 180
    static let bannerPadding: CGFloat = 10
    static let bannerCornerRadius: CGFloat = 14
    static let lineGap: CGFloat = 10
    static let pathGap: CGFloat = 2
    static let sectionGap: CGFloat = 16
    static let pagePadding: CGFloat = 24
}

/// The identifiers an e2e driver finds the chrome by.
enum DraftPreviewAccessibilityID {
    static let root = "rovenue-draft-preview"
    static let close = "rovenue-draft-preview-close"
    static let restart = "rovenue-draft-preview-restart"
    static let badge = "rovenue-draft-preview-badge"
    static let issues = "rovenue-draft-preview-issues"
    static let cantRender = "rovenue-draft-preview-cant-render"
    static let ended = "rovenue-draft-preview-ended"
    static let outcome = "rovenue-draft-preview-outcome"
}

private enum Copy {
    static let badge = "Draft preview · live"
    static let close = "Close preview"
    static let restart = "Restart preview"
    static let ended = "Preview ended"
    static let cantRenderTitle = "Can't render this draft"
    static let cantRenderDetail = "Fix these in the builder. The preview refreshes on its own."
    static func issuesSummary(_ count: Int) -> String {
        count == 1 ? "1 issue would block publishing" : "\(count) issues would block publishing"
    }
    static let outcomeDetail = "Simulated — nothing was charged or recorded. Your app would close the funnel here."
    static func purchased(_ name: String) -> String { name.isEmpty ? "Purchased" : "Purchased \(name)" }
    static let restored = "Purchases restored"
    static let finished = "Funnel finished"
    static let restartFunnel = "Restart funnel"
    static let closePreview = "Close preview"
}
#endif
