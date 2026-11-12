//  Photo.swift — the `photo_upload` question (spec A §4) and the `check`
//  block (spec C §3.5, §5).
//
//  The question draws a pick area until it is answered, then the photo with
//  its `changeLabel` control; the privacy line sits under the box. Picking
//  goes through the system pickers — `PhotosPicker` (no library
//  permission) and, when the host declares `NSCameraUsageDescription` and
//  the device has one, the camera — and the result is normalised into the
//  SDK's photo store (`FunnelPhotos.swift`) before the answer is reported.
//  Whether the question is answered is the resolver's `photo`: a `local:`
//  file that is gone reads as unanswered there and draws the pick area here.
//
//  The check block draws what the machine knows (`phase`, `steps`) plus the
//  one thing only the host knows: that a check is running
//  (`funnelRunningChecks`, installed by the driver while `onCheck` works).

import Foundation
import SwiftUI

#if os(iOS)
    import PhotosUI
    import UIKit
#endif

private enum PhotoFormat {
    /// The box the pick area and the preview share, so answering never
    /// moves the page: 4:3, width over height.
    static let boxAspect: CGFloat = 4.0 / 3.0
    static let pickGlyph = "photo.on.rectangle"
    static let cameraGlyph = "camera"
    static let changeGlyph = "arrow.triangle.2.circlepath"
    static let sourceLibrary = "library"
    static let sourceCamera = "camera"
    /// The source choice's two buttons: SDK chrome — the same words as
    /// Android's system dialog. Each is the tree's `cameraLabel` /
    /// `libraryLabel` where the visitor's language is not `en` (spec F §7
    /// N1, P106); absent or empty, the English word.
    static let libraryChoiceLabel = "Photo library"
    static let cameraChoiceLabel = "Camera"
    static let cameraUsageKey = "NSCameraUsageDescription"
    #if DEBUG
        /// Debug builds only: offers the camera without one (the simulator)
        /// so a proof can open the source choice; picking it there is not
        /// supported.
        static let forceCameraEnv = "ROVENUE_DEBUG_OFFER_CAMERA"
    #endif
    static let half: CGFloat = 2
    /// A check step's and badge's glyph per status.
    static let passGlyph = "checkmark.circle.fill"
    static let failGlyph = "xmark.circle.fill"
    static let skippedGlyph = "minus.circle"
    static let pendingGlyph = "circle"
    /// The check badge's box, as check.tsx draws it (`BADGE_PADDING`, gap, `GLYPH`).
    static let badgePaddingX: CGFloat = 14
    static let badgePaddingY: CGFloat = 8
    static let badgeGap: CGFloat = 8
    static let badgeGlyph: CGFloat = 18
    /// Spec F §8 H10: an authored step size draws the status symbol at the
    /// web ring's outer edge — check.tsx's r=10 ring, stroke 2, in a 24 box.
    static let authoredRingShare: CGFloat = 22.0 / 24.0
    /// Spec F §6 F2 pick looks (absent = `area`, today) and their glyphs
    /// (P82): `plus` = a `buttonMinHeight` disc in `tableHighlight` with a
    /// 28 pt accent `+`; `pill` = an accent pill, `onAccent` copy at button
    /// metrics, a 20 pt glyph. An authored `pickIcon` keeps the crate's paint.
    static let pickPlus = "plus"
    static let pickPill = "pill"
    static let plusGlyph = "plus"
    static let plusGlyphSize: CGFloat = 28
    static let pillGlyphSize: CGFloat = 20
    /// The change control's corner (absent = `bottomEnd`, today).
    static let changeTopStart = "topStart"
    static let changeTopEnd = "topEnd"
    static let changeBottomStart = "bottomStart"
    /// `privacyPlacement: none` hides the built-in privacy line.
    static let privacyNone = "none"
}

/// Reports a picked photo: the question's block id, the `local:` reference
/// and what the host is handed.
typealias FunnelPhotoReport = (String, String, FunnelPhotoRef) -> Void

struct FunnelPhotoQuestionView: View {
    let block: QuestionBlock
    let photo: RenderPhotoQuestion
    let look: RenderLook
    let onPhoto: FunnelPhotoReport

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var picking = false
    @State private var shooting = false
    @State private var choosingSource = false
    @State private var working = false
    @State private var picked: PickedItem?

    private var rowText: FunnelRowText {
        FunnelRowText(look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize))
    }

    /// The answered photo's `local:` reference, when its file is still there.
    private var answeredRef: String? {
        guard case .photo(let ref) = photo.photo, FunnelPhotoStore.fileURL(forRef: ref) != nil else {
            return nil
        }
        return ref
    }

    /// The style `funnelBox` draws the frame with: an authored border with
    /// no authored radius follows the fill's `look.cardRadius` (one radius
    /// for fill and outline, W3c-FI open item); otherwise as authored.
    /// Spec F §8 H7: once a photo shows, an authored `answeredBorder`
    /// replaces the block's own border — solid, width 0 drawing none.
    private var frameStyle: RenderStyle {
        var style = block.style
        if answeredRef != nil, let answered = photo.answeredBorder {
            let drawn = answered.width > 0
            style.borderWidth = drawn ? answered.width : nil
            style.borderColor = drawn ? answered.color : nil
            style.borderStyle = nil
        }
        if style.radius == nil, style.borderWidth != nil { style.radius = look.cardRadius }
        return style
    }

    /// Spec F §8 H11: the authored gap between the pick glyph and its copy.
    private var pickGap: CGFloat? { photo.pickGap.map(CGFloat.init) }

    /// Spec F §7 G1: the `plus` disc / `pill` plate and the glyph (and the
    /// pill's text); nil sides keep P82's paint. An authored `pickIcon` is
    /// already painted in `pickColor` by the crate.
    private var pickPlate: Color? { funnelColor(photo.pickBackground) }
    private var pickInk: Color? { funnelColor(photo.pickColor) }

    private var offersLibrary: Bool { photo.sources.contains(PhotoFormat.sourceLibrary) }

    /// The camera is offered only when the document allows it, the host
    /// declared why it needs it (iOS refuses camera access otherwise — a
    /// crash, not a prompt), and the device has one.
    private var offersCamera: Bool {
        #if DEBUG
            if ProcessInfo.processInfo.environment[PhotoFormat.forceCameraEnv] != nil {
                return photo.sources.contains(PhotoFormat.sourceCamera)
            }
        #endif
        guard photo.sources.contains(PhotoFormat.sourceCamera),
            Bundle.main.object(forInfoDictionaryKey: PhotoFormat.cameraUsageKey) != nil
        else { return false }
        #if os(iOS)
            return UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
            return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(look.cardGap)) {
            box
                .modifier(PhotoFrameFill(style: block.style, look: look))
                .funnelBox(frameStyle, look.bodyType)
            if photo.privacyPlacement != PhotoFormat.privacyNone, let privacy = photo.privacyLabel, !privacy.isEmpty {
                Text(privacy)
                    .font(rowText.secondaryFont(weight: look.textWeight))
                    .foregroundColor(look.mutedColor)
                    .funnelLineHeight(look, size: rowText.secondary, family: rowText.family)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .funnelOuter(block.style)
        // Both sources offered: the pick tap and the Change pill ask which
        // (web parity — the browser's own sheet; Android's system dialog).
        .confirmationDialog(photo.pickLabel, isPresented: $choosingSource, titleVisibility: .hidden) {
            Button(photo.libraryLabel.flatMap { $0.isEmpty ? nil : $0 } ?? PhotoFormat.libraryChoiceLabel) { picking = true }
            Button(photo.cameraLabel.flatMap { $0.isEmpty ? nil : $0 } ?? PhotoFormat.cameraChoiceLabel) { shooting = true }
        }
        .modifier(PhotoPickers(
            picking: $picking, shooting: $shooting, item: $picked, onData: store))
    }

    @ViewBuilder
    private var box: some View {
        if let ref = answeredRef {
            frameBox {
                FunnelLocalPhoto(ref: ref) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
                .clipped()
                .overlay(alignment: changeAlignment) { changeControl }
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
        } else {
            Button(action: start) {
                pickArea
            }
            .buttonStyle(FunnelRowPress(look: look))
            .disabled(working || (!offersLibrary && !offersCamera))
        }
    }

    /// The SF glyph the pick control draws when the author picked none.
    private var defaultGlyph: String { offersLibrary ? PhotoFormat.pickGlyph : PhotoFormat.cameraGlyph }

    @ViewBuilder
    private var pickArea: some View {
        Group {
            if photo.pickStyle == PhotoFormat.pickPill {
                pickPill
            } else {
                VStack(spacing: pickGap ?? CGFloat(look.tileLabelGap)) {
                    if working {
                        ProgressView()
                    } else {
                        pickGlyph
                    }
                    Text(photo.pickLabel)
                        .font(rowText.primaryFont(weight: look.labelWeight))
                        .funnelLineHeight(look, size: rowText.primary, family: rowText.family)
                    Text(photo.pickHint)
                        .font(rowText.secondaryFont(weight: look.textWeight))
                        .foregroundColor(look.mutedColor)
                        .funnelLineHeight(look, size: rowText.secondary, family: rowText.family)
                }
                .multilineTextAlignment(.center)
                .padding(CGFloat(look.cardPadding))
            }
        }
        // Spec F §8 H8: the control's authored move inside the empty frame
        // — x toward the trailing edge (SwiftUI mirrors an offset under a
        // right-to-left layout, checked), y down — the frame keeps its size.
        .ifLet(photo.pickOffset) { $0.offset(x: CGFloat($1.x), y: CGFloat($1.y)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PhotoFrameBox(fixedHeight: block.style.height != nil))
        .contentShape(Rectangle())
    }

    /// The frame the photo and the pick control share: full width at 4:3,
    /// or — with an authored height — the full box `funnelBox` sizes
    /// (`photo.tsx`'s frame: `width: 100%`, `aspect-ratio: 4 / 3`).
    private func frameBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PhotoFrameBox(fixedHeight: block.style.height != nil))
    }

    /// `area`'s glyph (today), or `plus`'s disc; an authored icon replaces
    /// the glyph in either.
    @ViewBuilder
    private var pickGlyph: some View {
        if photo.pickStyle == PhotoFormat.pickPlus {
            let side = CGFloat(look.buttonMinHeight)
            Circle()
                .fill(pickPlate ?? lookColor(look.tableHighlight))
                .frame(width: side, height: side)
                .overlay {
                    if let icon = photo.pickIcon {
                        FunnelIconGlyph(icon: icon)
                    } else {
                        Image(systemName: PhotoFormat.plusGlyph)
                            .font(.system(size: PhotoFormat.plusGlyphSize))
                            .foregroundColor(pickInk ?? look.accentColor)
                    }
                }
        } else if let icon = photo.pickIcon {
            FunnelIconGlyph(icon: icon)
        } else {
            Image(systemName: defaultGlyph)
                .font(.system(size: CGFloat(look.tileIconSize)))
                .foregroundColor(look.accentColor)
        }
    }

    /// `pill`: one accent pill centred in the frame, the glyph and the pick
    /// label at button metrics; the hint is not drawn (P82).
    private var pickPill: some View {
        HStack(spacing: pickGap ?? CGFloat(look.chipGap)) {
            if working {
                ProgressView().tint(pickInk ?? look.onAccentColor)
            } else if let icon = photo.pickIcon {
                FunnelIconGlyph(icon: icon)
            } else {
                Image(systemName: defaultGlyph).font(.system(size: PhotoFormat.pillGlyphSize))
            }
            Text(photo.pickLabel)
                .font(funnelFont(
                    size: CGFloat(look.buttonFontSize), weight: look.buttonFontWeight, family: rowText.family,
                    scale: rowText.scale))
        }
        .foregroundColor(pickInk ?? look.onAccentColor)
        .padding(.horizontal, CGFloat(look.buttonPaddingX))
        .frame(minHeight: CGFloat(look.buttonMinHeight))
        .background(RoundedRectangle(cornerRadius: CGFloat(look.badgeRadius)).fill(pickPlate ?? look.accentColor))
    }

    /// The change control's corner of the photo, logical (mirrors in RTL).
    private var changeAlignment: Alignment {
        switch photo.changePosition {
        case PhotoFormat.changeTopStart: return .topLeading
        case PhotoFormat.changeTopEnd: return .topTrailing
        case PhotoFormat.changeBottomStart: return .bottomLeading
        default: return .bottomTrailing
        }
    }

    private var changeControl: some View {
        Button(action: start) {
            HStack(spacing: CGFloat(look.badgePaddingX) / PhotoFormat.half) {
                Image(systemName: PhotoFormat.changeGlyph)
                Text(photo.changeLabel)
            }
            .font(.system(size: CGFloat(look.badgeFontSize), weight: funnelFontWeight(look.badgeWeight)))
            .padding(.horizontal, CGFloat(look.badgePaddingX))
            .padding(.vertical, CGFloat(look.badgePaddingY))
            // `changeStyle: glass` (spec F §6 F2) is a stack's surface, drawn
            // by the one stack glass with its fallbacks; solid is today's.
            .modifier(ChangePlate(surface: photo.changeSurface, radius: look.badgeRadius))
        }
        .buttonStyle(.plain)
        .disabled(working)
        .padding(CGFloat(look.tileLabelGap))
    }

    /// Both sources: the choice; else the one offered.
    private func start() {
        if offersLibrary && offersCamera {
            choosingSource = true
        } else if offersLibrary {
            picking = true
        } else if offersCamera {
            shooting = true
        }
    }

    /// Normalises and stores off the main thread, then reports.
    private func store(_ data: Data) {
        working = true
        let blockId = block.blockId
        Task {
            let stored = await Task.detached(priority: .userInitiated) {
                try? FunnelPhotoStore.store(imageData: data)
            }.value
            working = false
            // A source the store refused (over 10 MB, not an image) answers
            // nothing: the pick area stays and the CTA stays held.
            guard let stored else { return }
            onPhoto(blockId, stored.ref, stored.photo)
        }
    }
}

/// Sizes the photo frame: 4:3 at the full proposed width — the content
/// laid over a clear 4:3 box, so a short pick control (the `pill`) never
/// shrinks the frame to its own height — or, with an authored height,
/// whatever box the style's fixed height gives.
private struct PhotoFrameBox: ViewModifier {
    let fixedHeight: Bool

    func body(content: Content) -> some View {
        if fixedHeight {
            // Over a clear box that takes exactly the proposed size: an
            // aspect-fill photo reports its own aspect's width (wider than
            // the column at a short authored height), which a flexible
            // frame would adopt — the frame ran off the screen and cut the
            // Change pill (W3-A2 D11). The photo covers, cropped; the
            // overlays stay inside the column.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { content }
        } else {
            Color.clear
                .aspectRatio(PhotoFormat.boxAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { content }
        }
    }
}

/// The frame's own surface where the author set none — `photo.tsx`'s
/// frame: `background: look.card`, `borderRadius: look.cardRadius`, each
/// replaced by the authored one (which `funnelBox` draws). The fill shows
/// behind the empty pick area and under a photo still loading (P91).
private struct PhotoFrameFill: ViewModifier {
    let style: RenderStyle
    let look: RenderLook

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
        if style.radius == nil {
            content
                .background(funnelColor(style.background) == nil ? look.cardColor : Color.clear)
                .clipShape(shape)
        } else {
            content.background(funnelColor(style.background) == nil ? look.cardColor : Color.clear)
        }
    }
}

/// The change pill's plate: the stack glass when authored, else today's
/// thin material capsule.
private struct ChangePlate: ViewModifier {
    let surface: RenderSurface?
    let radius: Int

    func body(content: Content) -> some View {
        if surface != nil {
            content.modifier(FunnelGlassSurface(surface: surface, radius: radius))
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}

/// A picked library item, opaque off iOS.
struct PickedItem: Equatable {
    #if os(iOS)
        let item: PhotosPickerItem
    #endif
}

/// The two system pickers, attached once to the question.
private struct PhotoPickers: ViewModifier {
    @Binding var picking: Bool
    @Binding var shooting: Bool
    @Binding var item: PickedItem?
    let onData: (Data) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .photosPicker(
                    isPresented: $picking,
                    selection: Binding(get: { item?.item }, set: { item = $0.map(PickedItem.init) }),
                    matching: .images, preferredItemEncoding: .compatible)
                .onChange(of: item) { picked in
                    guard let picked else { return }
                    item = nil
                    Task {
                        if let data = try? await picked.item.loadTransferable(type: Data.self) {
                            onData(data)
                        }
                    }
                }
                .fullScreenCover(isPresented: $shooting) {
                    FunnelCameraPicker { data in
                        shooting = false
                        if let data { onData(data) }
                    }
                    .ignoresSafeArea()
                }
        #else
            content
        #endif
    }
}

#if os(iOS)
    /// `UIImagePickerController(.camera)`: hands back the shot as JPEG bytes
    /// (the store re-encodes and strips them), or nil when cancelled.
    private struct FunnelCameraPicker: UIViewControllerRepresentable {
        let onDone: (Data?) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onDone: (Data?) -> Void
            /// Lossless enough for the store's own 0.85 re-encode.
            private static let handoffQuality: CGFloat = 1

            init(onDone: @escaping (Data?) -> Void) { self.onDone = onDone }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                let image = info[.originalImage] as? UIImage
                onDone(image?.jpegData(compressionQuality: Self.handoffQuality))
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
        }
    }
#endif

// MARK: - Check

/// The check keys whose host check is running now — the one phase the
/// machine does not know (`running`, spec C §3.5). Installed per screen by
/// `FunnelDriverView` from `FunnelDriver.runningChecks`.
private struct FunnelRunningChecksKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var funnelRunningChecks: Set<String> {
        get { self[FunnelRunningChecksKey.self] }
        set { self[FunnelRunningChecksKey.self] = newValue }
    }
}

/// While a check on the page runs, its `checkingLabel`: every button and
/// purchase button on the page is held (spec C §3.1) and keeps its own
/// label (P83, spec F §8 N2); non-nil means "a check runs".
private struct FunnelCheckingLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var funnelCheckingLabel: String? {
        get { self[FunnelCheckingLabelKey.self] }
        set { self[FunnelCheckingLabelKey.self] = newValue }
    }
}

/// While a check on the page runs, the synthesized Continue's label: the
/// check's `ctaCheckingLabel` when authored, else its `checkingLabel`
/// (spec F §6 F3d, P83 — Button blocks keep their own label). An empty one
/// leaves the Continue's own label (`holdForCheck`'s `||` chain).
private struct FunnelCtaCheckingLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var funnelCtaCheckingLabel: String? {
        get { self[FunnelCtaCheckingLabelKey.self] }
        set { self[FunnelCtaCheckingLabelKey.self] = newValue }
    }
}

extension CheckBlock {
    static let phaseIdle = "idle"
    static let phaseRunning = "running"
    static let phasePass = "pass"
    static let phaseFail = "fail"
    static let phaseSkipped = "skipped"
    static let displayBadge = "badge"
    static let statusPass = "pass"
    static let statusFail = "fail"
    static let statusRunning = "running"
    static let statusSkipped = "skipped"
    static let statusPending = "pending"
}

struct FunnelCheckView: View {
    let block: CheckBlock
    let look: RenderLook

    @Environment(\.funnelRunningChecks) private var running
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var rowText: FunnelRowText {
        FunnelRowText(look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize))
    }

    /// The machine's phase, or `running` while the host checks.
    private var phase: String { running.contains(block.key) ? CheckBlock.phaseRunning : block.phase }

    var body: some View {
        Group {
            if block.display == CheckBlock.displayBadge {
                badge
            } else {
                list
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    /// The badge text for this phase: `checkingLabel` while running, the
    /// resolved pass/fail label after, nothing before.
    private var badgeLabel: String? {
        switch phase {
        case CheckBlock.phaseRunning: return block.checkingLabel
        case CheckBlock.phaseIdle: return nil
        default: return block.badgeText
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let label = badgeLabel, !label.isEmpty {
            // Spec F §8 N4 (check.tsx): one plate for every phase — the
            // look's card under the look's text; the glyph alone carries
            // the tone (a success disc with an onSuccess tick, a danger disc
            // with a white cross, the spinner).
            HStack(spacing: PhotoFormat.badgeGap) {
                badgeGlyph(phase)
                    .frame(width: PhotoFormat.badgeGlyph, height: PhotoFormat.badgeGlyph)
                Text(label)
                    .font(funnelFont(
                        size: CGFloat(look.mutedTextSize), weight: look.emphasisWeight, family: rowText.family,
                        scale: rowText.scale))
            }
            .foregroundColor(look.textColor)
            .padding(.horizontal, PhotoFormat.badgePaddingX)
            .padding(.vertical, PhotoFormat.badgePaddingY)
            .background(look.cardColor, in: RoundedRectangle(cornerRadius: CGFloat(look.badgeRadius)))
            .accessibilityElement(children: .combine)
        }
    }

    /// The badge's glyph, as check.tsx's `StatusGlyph` paints it: the
    /// filled disc in the status colour with the mark cut in its own colour.
    @ViewBuilder
    private func badgeGlyph(_ phase: String) -> some View {
        switch phase {
        case CheckBlock.statusPass:
            Image(systemName: PhotoFormat.passGlyph).resizable().scaledToFit()
                .symbolRenderingMode(.palette)
                .foregroundStyle(lookColor(look.onSuccess), lookColor(look.success))
        case CheckBlock.statusFail:
            Image(systemName: PhotoFormat.failGlyph).resizable().scaledToFit()
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, look.dangerColor)
        default:
            glyph(phase)
        }
    }

    /// The checked photo's `local:` reference — the web draws only a
    /// visitor's photo here (`usePhotoUrl` of a `photo` medium), so a URL
    /// medium draws nothing on any drawer — nor does an author-hidden one
    /// (`showPhoto: false`, Spec F §6 F3).
    private var photoRef: String? {
        if block.showPhoto != false, case .photo(let ref) = block.photo { return ref }
        return nil
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: CGFloat(look.rowGap)) {
            // The photo being checked, above the steps (check.tsx): full
            // width, 4:3, aspect fill, the look's card corners. A gone file
            // draws nothing — no empty box, no spacing. (Not an `EmptyView`
            // placeholder: an empty view never appears, so the loader's
            // `.task` never ran and the photo never drew.)
            if let ref = photoRef, FunnelPhotoStore.fileURL(forRef: ref) != nil {
                Color.clear
                    .aspectRatio(PhotoFormat.boxAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        FunnelLocalPhoto(ref: ref) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(look.cardRadius)))
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            if inCard {
                // Spec F §6 F3c / P83: the rows in ONE card — the surface's
                // fill and radius, else the look's card — with full-width
                // lines in the divider's colour between them (`none` or
                // absent: no line).
                VStack(spacing: 0) {
                    ForEach(Array(block.steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0, let line = dividerColor {
                            line.frame(height: CGFloat(look.borderWidth))
                        }
                        stepRow(step)
                            .padding(.horizontal, CGFloat(look.rowPaddingX))
                            .padding(.vertical, block.rowHeight == nil ? CGFloat(look.rowPaddingY) : 0)
                    }
                }
                .background(funnelColor(block.surface?.background) ?? look.cardColor)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.surface?.radius ?? look.cardRadius)))
            } else {
                ForEach(block.steps, id: \.id) { step in stepRow(step) }
            }
            // check.tsx's one line UNDER the steps: `checkingLabel` while the
            // check runs, the resolved text after — muted (danger on a fail)
            // at `mutedTextSize`; an empty one takes no line (spec F §8 N1).
            if phase != CheckBlock.phaseIdle, let text = badgeLabel, !text.isEmpty {
                Text(text)
                    .font(funnelFont(
                        size: CGFloat(look.mutedTextSize), weight: look.textWeight, family: rowText.family,
                        scale: rowText.scale))
                    .foregroundColor(phase == CheckBlock.phaseFail ? look.dangerColor : look.mutedColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Spec F §6 F3c: a surface or a divider puts the rows in one card.
    private var inCard: Bool { block.surface != nil || block.divider != nil }
    private static let dividerNone = "none"
    private var dividerColor: Color? {
        guard let divider = block.divider, divider != Self.dividerNone else { return nil }
        return funnelColor(divider)
    }

    /// One step: glyph and label; an authored `rowHeight` is exact.
    private func stepRow(_ step: RenderCheckStep) -> some View {
        // While the host checks, every step reads running; the
        // outcome lands all at once (spec C §5, C14).
        let status = phase == CheckBlock.phaseRunning ? CheckBlock.statusRunning : step.status
        // Spec F §8 H10: an authored `indicatorSize` / `pendingColor` reach
        // the list's step glyphs only — the badge keeps its 18 pt glyph.
        let authored = block.indicatorSize.map(CGFloat.init)
        let size = authored ?? CGFloat(look.indicatorSize)
        return HStack(spacing: CGFloat(look.indicatorGap)) {
            glyph(status, pending: funnelColor(block.pendingColor), authoredSize: authored)
                .frame(width: size, height: size)
            Text(step.label)
                .font(rowText.primaryFont(weight: look.textWeight))
                .foregroundColor(labelColor(status))
            Spacer(minLength: 0)
        }
        .ifLet(block.rowHeight) { $0.frame(height: CGFloat($1)) }
        .accessibilityElement(children: .combine)
    }

    /// A step label's colour: text once decided; a pending step's authored
    /// `pendingLabelColor` (spec F §9 I4, the pending status only — as web
    /// check.tsx); muted otherwise.
    private func labelColor(_ status: String) -> Color {
        if status == CheckBlock.statusPass || status == CheckBlock.statusFail { return look.textColor }
        if status == CheckBlock.statusPending, let c = funnelColor(block.pendingLabelColor) { return c }
        return look.mutedColor
    }

    /// A step's or the badge's glyph for a status/phase.
    /// `tint` overrides the status colour — on the badge's own fill.
    /// `pending` is a step's authored pending-ring colour and
    /// `authoredSize` its authored size (spec F §8 H10); both nil on the
    /// badge and when unauthored.
    @ViewBuilder
    private func glyph(
        _ status: String, tint: Color? = nil, pending: Color? = nil, authoredSize: CGFloat? = nil
    ) -> some View {
        switch status {
        case CheckBlock.statusRunning:
            ProgressView().controlSize(.small).tint(tint)
        case CheckBlock.statusPass:
            symbol(PhotoFormat.passGlyph, authoredSize).foregroundColor(tint ?? lookColor(look.success))
        case CheckBlock.statusFail:
            symbol(PhotoFormat.failGlyph, authoredSize).foregroundColor(tint ?? look.dangerColor)
        case CheckBlock.statusSkipped:
            symbol(PhotoFormat.skippedGlyph, authoredSize).foregroundColor(tint ?? look.mutedColor)
        default:
            symbol(PhotoFormat.pendingGlyph, authoredSize).foregroundColor(tint ?? pending ?? look.mutedColor)
        }
    }

    /// A status symbol at its natural size, or — authored (spec F §8 H10) —
    /// scaled to the web ring's outer edge inside the authored box.
    @ViewBuilder
    private func symbol(_ name: String, _ authoredSize: CGFloat?) -> some View {
        if let authoredSize {
            let d = authoredSize * PhotoFormat.authoredRingShare
            Image(systemName: name).resizable().scaledToFit().frame(width: d, height: d)
        } else {
            Image(systemName: name)
        }
    }
}

// MARK: - Screen walks

extension RenderBlock {
    /// The blocks drawn inside this one, in order.
    var childBlocks: [RenderBlock] {
        switch self {
        case .stack(let b): return b.children
        case .stickyFooter(let b): return b.children
        case .expressCheckout(let b): return b.children
        case .carousel(let b): return b.children
        case .accordion(let b): return b.items.flatMap(\.children)
        case .popup(let b): return b.children
        default: return []
        }
    }
}

extension RenderScreen {
    /// Every block on the screen, containers' children included.
    var allBlocks: [RenderBlock] {
        var out: [RenderBlock] = []
        func walk(_ blocks: [RenderBlock]) {
            for block in blocks {
                out.append(block)
                walk(block.childBlocks)
            }
        }
        walk(header)
        walk(blocks)
        walk(overlay)
        return out
    }

    /// The screen's photo questions.
    var photoQuestions: [QuestionBlock] {
        allBlocks.compactMap { block in
            if case .question(let q) = block, q.photo != nil { return q }
            return nil
        }
    }

    /// A running check's `checkingLabel` (spec C §3.1: one check per page),
    /// or nil while none of this screen's checks runs.
    func checkingLabel(running: Set<String>) -> String? {
        guard !running.isEmpty else { return nil }
        for block in allBlocks {
            if case .check(let check) = block, running.contains(check.key) { return check.checkingLabel }
        }
        return nil
    }

    /// The CTA's label while a check runs: `ctaCheckingLabel` when the
    /// running check authored a non-empty one, else its `checkingLabel`.
    func ctaCheckingLabel(running: Set<String>) -> String? {
        guard !running.isEmpty else { return nil }
        for block in allBlocks {
            if case .check(let check) = block, running.contains(check.key) {
                if let label = check.ctaCheckingLabel, !label.isEmpty { return label }
                return check.checkingLabel
            }
        }
        return nil
    }
}
