//  DraftIssuesView.swift — "Can't render this draft": what the placement
//  view draws when a debug + Sandbox build was served a draft that cannot be
//  served (spec 2026-10-17 §3.5, §3.5a; FM6). The list is the API's own
//  issues — the same ones that would block a publish — so the developer
//  sees why the funnel is not on screen, and the view keeps refreshing: the
//  next edit that fixes them brings the funnel back on its own.
//
//  SDK chrome, not funnel drawing: system fonts and materials only.

import SwiftUI

/// The full-screen refusal: the draft cannot be drawn, and why.
struct DraftIssuesView: View {
    let issues: [DraftIssue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DraftIssuesMetrics.sectionGap) {
                Label(DraftIssuesCopy.title, systemImage: DraftIssuesCopy.symbol)
                    .font(.title3.bold())
                    .accessibilityIdentifier(DraftIssuesAccessibilityID.title)
                Text(DraftIssuesCopy.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: DraftIssuesMetrics.lineGap) {
                    // Issues carry no id of their own, and two may say the
                    // same thing at the same path: the position is the id.
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: DraftIssuesMetrics.pathGap) {
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
            .padding(DraftIssuesMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear.background(.background).ignoresSafeArea())
    }
}

private enum DraftIssuesMetrics {
    static let sectionGap: CGFloat = 16
    static let lineGap: CGFloat = 10
    static let pathGap: CGFloat = 2
    static let pagePadding: CGFloat = 24
}

/// The identifiers an e2e driver finds the refusal by.
enum DraftIssuesAccessibilityID {
    static let title = "rovenue-draft-cant-render"
}

private enum DraftIssuesCopy {
    static let title = "Can't render this draft"
    static let detail = "Fix these in the builder. This screen refreshes on its own."
    static let symbol = "exclamationmark.triangle.fill"
}
