//  Fields.swift — the one field box every text, number, date and contact
//  field draws (spec D1), the SwiftUI twin of `fieldStyle` in the web's
//  `blocks/questions.tsx`.
//
//  The box is a `card` fill, a `borderWidth` hairline in `border` and
//  `cardRadius`; focused, the border is `selectedBorderWidth` in `accent`;
//  an answer the resolver refused (once revealed — see `funnelInvalidText`
//  in Questions.swift) turns it `danger`, its message under the box.
//  The border is drawn OVER the padding band (`strokeBorder`), so the
//  thicker focused border never moves the text. The text sits
//  `fieldPaddingY` × `fieldPaddingX` inside the hairline, at the row's
//  primary size in `textWeight`, in the block's colour or `look.text`; the
//  placeholder, a number's suffix and a date's glyph are `muted`, the last
//  two inside the trailing padding.
//
//  On iOS the input is a UIKit text field that FILLS the box, insetting
//  its own text: the field's accessibility frame is then the box a visitor
//  sees and taps, not a strip inside it. A date field is the same text
//  field with a date wheel as its keyboard, so all five field kinds share
//  one box, one focus rule and one accessibility shape.

import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum FieldFormat {
    /// The SF Symbol drawn at a date field's trailing edge — the web's
    /// lucide `Calendar`.
    static let calendarSymbol = "calendar"
    /// The numeric date pattern a date field shows — picked or empty — in
    /// the device's own field order: the browser's `dd.mm.yyyy` on the web.
    static let dateTemplate = "ddMMyyyy"
    static let half: CGFloat = 2

    /// The pattern itself (`dd.MM.yyyy`, `MM/dd/yyyy`, …) for this locale.
    static var datePattern: String {
        DateFormatter.dateFormat(fromTemplate: dateTemplate, options: 0, locale: .current)
            ?? dateTemplate
    }

    /// A picked date, in the numeric pattern an empty field shows.
    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = datePattern
        return formatter.string(from: date)
    }
}

/// What a field reports and how its keyboard behaves.
enum FunnelFieldInput: Equatable {
    /// Free text, sentence-capitalised and autocorrected (short text).
    case sentence
    /// A person's name.
    case name
    case email
    case phone
    case decimal
    /// A calendar date, picked on a wheel — never typed.
    case date
}

/// Drawn inside the trailing padding, in `muted`.
enum FunnelFieldTrailing: Equatable {
    case suffix(String)
    case calendar
}

/// The inset of a field's text from the box's outer edge: the hairline,
/// then the field padding. Fixed — focus only thickens the border inside
/// the padding band.
private func fieldInsets(_ look: RenderLook) -> EdgeInsets {
    let x = CGFloat(look.fieldPaddingX + look.borderWidth)
    let y = CGFloat(look.fieldPaddingY + look.borderWidth)
    return EdgeInsets(top: y, leading: x, bottom: y, trailing: x)
}

extension View {
    /// The field box around an input that fills it. A shown refusal wins
    /// the border's colour over focus (`fieldStyle` on the web); focus
    /// still sets its width.
    func funnelFieldBox(
        _ look: RenderLook, focused: Bool, invalid: Bool = false, minHeight: Int
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
        let edge = invalid ? look.dangerColor : focused ? look.accentColor : look.borderColor
        return self
            .frame(maxWidth: .infinity, minHeight: CGFloat(minHeight))
            .background(shape.fill(look.cardColor))
            .overlay(
                shape.strokeBorder(
                    edge,
                    lineWidth: CGFloat(focused ? look.selectedBorderWidth : look.borderWidth))
                .allowsHitTesting(false))
    }

    /// The field, and under it — `rowGap` apart — why its answer cannot
    /// be used, when `message` is shown. `onBlur` hears the field lose
    /// focus (the reveal rule's first half).
    fileprivate func funnelInvalidBelow(
        _ message: String?, look: RenderLook, focused: Bool, onBlur: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(look.rowGap)) {
            self
            if let message { FunnelInvalidMessage(message: message, look: look) }
        }
        .onChange(of: focused) { if !$0 { onBlur?() } }
    }
}

/// Why a field's answer cannot be used: the look's `danger`, at
/// `mutedTextSize` in `textWeight` — the web's message span under the
/// field. Left readable by VoiceOver as well as carried by the field's
/// hint, so a visitor swiping past the field still finds it.
private struct FunnelInvalidMessage: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts
    let message: String
    let look: RenderLook

    var body: some View {
        Text(message)
            .funnelTextFont(.unstyled, look.mutedType, scale: FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts))
            .foregroundColor(look.dangerColor)
            .funnelLineHeight(look, size: look.mutedTextSize, family: nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single-line field: short text, email, phone, number, date and each
/// contact field.
struct FunnelField: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts
    let look: RenderLook
    let rowText: FunnelRowText
    /// The block's authored colour — the typed text's, never the
    /// placeholder's.
    let color: String?
    let placeholder: String
    let input: FunnelFieldInput
    let trailing: FunnelFieldTrailing?
    @Binding var text: String
    /// A date field's picked date (seeded from the resolver's answer).
    var date: Date? = nil
    var onDate: ((Date) -> Void)? = nil
    /// Why the answer cannot be used, once revealed; nil draws nothing.
    var invalidMessage: String? = nil
    /// The field lost focus.
    var onBlur: (() -> Void)? = nil

    @State private var focused = false

    var body: some View {
        input_
            .funnelFieldBox(
                look, focused: focused, invalid: invalidMessage != nil, minHeight: look.fieldMinHeight)
            .funnelInvalidBelow(invalidMessage, look: look, focused: focused, onBlur: onBlur)
    }

    @ViewBuilder
    private var input_: some View {
        #if canImport(UIKit)
            FunnelUIKitField(
                placeholder: effectivePlaceholder,
                font: funnelUIFont(
                    size: rowText.primary, weight: look.textWeight, family: rowText.family,
                    fonts: rowText.scale.fonts),
                strokeWidth: funnelFakeBoldStrokePercent(
                    size: rowText.primary, weight: look.textWeight, family: rowText.family, scale: rowText.scale),
                textColor: UIColor(funnelColor(color) ?? look.textColor),
                mutedColor: UIColor(look.mutedColor),
                insets: fieldInsets(look),
                lineBox: funnelLineBox(look, size: rowText.primary, scale: rowText.scale),
                trailingGap: CGFloat(look.indicatorGap),
                trailing: trailing,
                input: input,
                text: $text,
                focused: $focused,
                date: date,
                onDate: onDate,
                invalidMessage: invalidMessage)
        #else
            HStack(spacing: CGFloat(look.indicatorGap)) {
                let stroke = funnelFakeBoldStrokePercent(
                    size: rowText.primary, weight: look.textWeight, family: rowText.family, scale: rowText.scale)
                if stroke != 0 {
                    FunnelAppKitField(
                        placeholder: effectivePlaceholder,
                        font: funnelNSFont(
                            size: rowText.primary, weight: look.textWeight, family: rowText.family,
                            fonts: rowText.scale.fonts),
                        strokeWidth: stroke, textColor: NSColor(funnelColor(color) ?? look.textColor),
                        mutedColor: NSColor(look.mutedColor), text: $text, invalidMessage: invalidMessage)
                } else {
                    TextField("", text: $text, prompt: Text(effectivePlaceholder).foregroundColor(look.mutedColor))
                        .textFieldStyle(.plain)
                        .font(rowText.primaryFont(weight: look.textWeight))
                        .ifLet(funnelColor(color)) { $0.foregroundColor($1) }
                        .ifLet(invalidMessage) { $0.accessibilityHint(Text($1)) }
                }
                if case .suffix(let s) = trailing {
                    Text(s).funnelTextFont(rowText, size: rowText.primary, weight: look.textWeight).foregroundColor(look.mutedColor)
                } else if trailing == .calendar {
                    Image(systemName: FieldFormat.calendarSymbol).foregroundColor(look.mutedColor)
                }
            }
            .padding(fieldInsets(look))
        #endif
    }

    /// An empty date field shows the date pattern, as a browser's date
    /// input does, unless the author wrote a placeholder.
    private var effectivePlaceholder: String {
        guard input == .date, placeholder.isEmpty else { return placeholder }
        return FieldFormat.datePattern.lowercased()
    }
}

/// A long-text field: the same box, `longTextMinHeight` tall, the
/// placeholder shown until something is typed.
struct FunnelTextArea: View {
    let look: RenderLook
    let rowText: FunnelRowText
    let color: String?
    let placeholder: String
    @Binding var text: String
    /// Why the answer cannot be used, once revealed; nil draws nothing.
    var invalidMessage: String? = nil
    /// The field lost focus.
    var onBlur: (() -> Void)? = nil

    @State private var focused = false

    var body: some View {
        let insets = fieldInsets(look)
        ZStack(alignment: .topLeading) {
            #if canImport(UIKit)
                FunnelUIKitTextArea(
                    placeholder: placeholder,
                    font: funnelUIFont(
                        size: rowText.primary, weight: look.textWeight, family: rowText.family,
                        fonts: rowText.scale.fonts),
                    strokeWidth: funnelFakeBoldStrokePercent(
                        size: rowText.primary, weight: look.textWeight, family: rowText.family, scale: rowText.scale),
                    textColor: UIColor(funnelColor(color) ?? look.textColor),
                    insets: insets,
                    text: $text,
                    focused: $focused,
                    invalidMessage: invalidMessage)
            #else
                let stroke = funnelFakeBoldStrokePercent(
                    size: rowText.primary, weight: look.textWeight, family: rowText.family, scale: rowText.scale)
                if stroke != 0 {
                    FunnelAppKitTextArea(
                        font: funnelNSFont(
                            size: rowText.primary, weight: look.textWeight, family: rowText.family,
                            fonts: rowText.scale.fonts),
                        strokeWidth: stroke, textColor: NSColor(funnelColor(color) ?? look.textColor),
                        placeholder: placeholder, text: $text, invalidMessage: invalidMessage
                    )
                    .padding(insets)
                } else {
                    TextEditor(text: $text)
                        .font(rowText.primaryFont(weight: look.textWeight))
                        .padding(insets)
                        .ifLet(invalidMessage) { $0.accessibilityHint(Text($1)) }
                }
            #endif
            if text.isEmpty {
                Text(placeholder)
                    .funnelTextFont(rowText, size: rowText.primary, weight: look.textWeight)
                    .foregroundColor(look.mutedColor)
                    .padding(insets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: CGFloat(look.longTextMinHeight))
        .funnelFieldBox(
            look, focused: focused, invalid: invalidMessage != nil, minHeight: look.longTextMinHeight)
        .funnelInvalidBelow(invalidMessage, look: look, focused: focused, onBlur: onBlur)
    }
}

#if canImport(UIKit)

    /// The UIKit font a field's text draws in: the authored family when the
    /// device has it, the system face otherwise — `funnelFont`'s rule.
    func funnelUIFont(size: CGFloat, weight: Int, family: String?, fonts: FunnelSessionFonts) -> UIFont {
        // `UIFont.Weight`'s raw value IS the CoreText trait the one weight
        // table carries, so the row's trait is the UIKit weight.
        if let face = fonts.face(family, weight: weight, italic: false) {
            // A synthesised bold CoreText could not apply draws the face.
            return funnelUploadedCTFont(face, size: size) as UIFont
        }
        let w = UIFont.Weight(rawValue: funnelCSSWeight(nearest: weight).trait)
        guard let family = funnelResolvedFontFamily(family) else {
            return .systemFont(ofSize: size, weight: w)
        }
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: w],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private extension UIEdgeInsets {
        init(_ e: EdgeInsets) {
            self.init(top: e.top, left: e.leading, bottom: e.bottom, right: e.trailing)
        }
    }

    /// A text field whose text, placeholder and trailing adornment sit
    /// inside fixed insets, so the view itself can be the whole box.
    final class FunnelInsetTextField: UITextField {
        var contentInsets: UIEdgeInsets = .zero {
            didSet { if contentInsets != oldValue { invalidateIntrinsicContentSize() } }
        }
        var trailingGap: CGFloat = 0
        /// The CSS line box of one line of text — with the insets, the
        /// field's natural height (the web's border-box field).
        var lineBox: CGFloat = 0 {
            didSet { if lineBox != oldValue { invalidateIntrinsicContentSize() } }
        }
        /// A date field: picked, never typed, so no caret.
        var picksOnly = false

        override var intrinsicContentSize: CGSize {
            CGSize(
                width: UIView.noIntrinsicMetric,
                height: lineBox + contentInsets.top + contentInsets.bottom)
        }

        override func textRect(forBounds bounds: CGRect) -> CGRect { content(bounds) }
        override func editingRect(forBounds bounds: CGRect) -> CGRect { content(bounds) }
        override func placeholderRect(forBounds bounds: CGRect) -> CGRect { content(bounds) }

        override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
            guard let size = trailingSize(bounds) else { return .zero }
            return CGRect(
                x: bounds.maxX - contentInsets.right - size.width,
                y: bounds.midY - size.height / FieldFormat.half,
                width: size.width, height: size.height)
        }

        override func caretRect(for position: UITextPosition) -> CGRect {
            picksOnly ? .zero : super.caretRect(for: position)
        }

        private func trailingSize(_ bounds: CGRect) -> CGSize? {
            guard let view = rightView else { return nil }
            return view.sizeThatFits(bounds.size)
        }

        private func content(_ bounds: CGRect) -> CGRect {
            var r = bounds.inset(by: contentInsets)
            if let size = trailingSize(bounds) { r.size.width -= size.width + trailingGap }
            return r
        }
    }

    struct FunnelUIKitField: UIViewRepresentable {
        let placeholder: String
        let font: UIFont
        /// Synthesised bold (`funnelFakeBoldStrokePercent`); 0: none.
        let strokeWidth: CGFloat
        let textColor: UIColor
        let mutedColor: UIColor
        let insets: EdgeInsets
        let lineBox: CGFloat
        let trailingGap: CGFloat
        let trailing: FunnelFieldTrailing?
        let input: FunnelFieldInput
        @Binding var text: String
        @Binding var focused: Bool
        let date: Date?
        let onDate: ((Date) -> Void)?
        /// Spoken as the field's hint while shown.
        let invalidMessage: String?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> FunnelInsetTextField {
            let field = FunnelInsetTextField()
            field.delegate = context.coordinator
            context.coordinator.field = field
            field.borderStyle = .none
            field.backgroundColor = .clear
            field.addTarget(
                context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
            field.setContentHuggingPriority(.required, for: .vertical)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            switch input {
            case .sentence:
                field.autocapitalizationType = .sentences
            case .name:
                field.autocapitalizationType = .words
                field.textContentType = .name
                field.autocorrectionType = .no
            case .email:
                field.keyboardType = .emailAddress
                field.textContentType = .emailAddress
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            case .phone:
                field.keyboardType = .phonePad
                field.textContentType = .telephoneNumber
            case .decimal:
                field.keyboardType = .decimalPad
            case .date:
                field.picksOnly = true
                let picker = UIDatePicker()
                picker.datePickerMode = .date
                picker.preferredDatePickerStyle = .wheels
                if let date {
                    picker.date = date
                    field.text = FieldFormat.display(date)
                }
                picker.addTarget(
                    context.coordinator, action: #selector(Coordinator.picked(_:)),
                    for: .valueChanged)
                field.inputView = picker
            }
            field.text = input == .date ? field.text : text
            switch trailing {
            case .suffix(let suffix):
                let label = UILabel()
                label.text = suffix
                field.rightView = label
            case .calendar:
                field.rightView = UIImageView(image: UIImage(systemName: FieldFormat.calendarSymbol))
            case nil:
                break
            }
            field.rightViewMode = .always
            return field
        }

        func updateUIView(_ field: FunnelInsetTextField, context: Context) {
            context.coordinator.parent = self
            field.contentInsets = UIEdgeInsets(insets)
            field.lineBox = lineBox
            field.trailingGap = trailingGap
            Self.paint(
                field, font: font, strokeWidth: strokeWidth, textColor: textColor, mutedColor: mutedColor,
                placeholder: placeholder)
            // The placeholder is the field's accessible name too: a field
            // needs one, and this is the only copy the author gave it.
            field.accessibilityLabel = placeholder
            // Why the answer cannot be used, read after the field's value.
            field.accessibilityHint = invalidMessage
            if input != .date, field.text != text { field.text = text }
        }

        /// The field's face, colours and placeholder — and its synthesised
        /// bold (review R5), which UIKit draws as a glyph stroke where
        /// SwiftUI Text cannot: on the text, the placeholder and a suffix.
        static func paint(
            _ field: UITextField, font: UIFont, strokeWidth: CGFloat, textColor: UIColor, mutedColor: UIColor,
            placeholder: String
        ) {
            field.font = font
            field.textColor = textColor
            field.defaultTextAttributes.merge(funnelFakeBoldAttributes(strokePercent: strokeWidth, color: textColor)) {
                $1
            }
            let muted = funnelFakeBoldAttributes(strokePercent: strokeWidth, color: mutedColor)
            field.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: muted.merging([.foregroundColor: mutedColor, .font: font]) { $1 })
            if let label = field.rightView as? UILabel {
                label.attributedText = NSAttributedString(
                    string: label.text ?? "",
                    attributes: muted.merging([.foregroundColor: mutedColor, .font: font]) { $1 })
            } else if let image = field.rightView as? UIImageView {
                image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                    pointSize: font.pointSize)
                image.tintColor = mutedColor
            }
        }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var parent: FunnelUIKitField

            init(_ parent: FunnelUIKitField) { self.parent = parent }

            @objc func edited(_ field: UITextField) {
                parent.text = field.text ?? ""
            }

            /// A date wheel is the field's input view, not its subview, so
            /// the coordinator keeps the field it writes the picked date to.
            weak var field: UITextField?

            @objc func picked(_ picker: UIDatePicker) {
                field?.text = FieldFormat.display(picker.date)
                parent.onDate?(picker.date)
            }

            func textFieldDidBeginEditing(_ textField: UITextField) {
                parent.focused = true
            }

            func textFieldDidEndEditing(_ textField: UITextField) {
                parent.focused = false
                // Leaving a date field accepts the date its wheel shows —
                // including the one it opened on, never turned.
                if parent.input == .date, let picker = textField.inputView as? UIDatePicker {
                    picked(picker)
                }
            }

            func textField(
                _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                replacementString string: String
            ) -> Bool {
                parent.input != .date
            }
        }
    }

    /// A multi-line field: a text view filling the box, its text inset
    /// like a field's.
    struct FunnelUIKitTextArea: UIViewRepresentable {
        let placeholder: String
        let font: UIFont
        /// Synthesised bold (`funnelFakeBoldStrokePercent`); 0: none.
        let strokeWidth: CGFloat
        let textColor: UIColor
        let insets: EdgeInsets
        @Binding var text: String
        @Binding var focused: Bool
        /// Spoken as the field's hint while shown.
        let invalidMessage: String?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.delegate = context.coordinator
            view.backgroundColor = .clear
            view.textContainer.lineFragmentPadding = 0
            view.text = text
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            context.coordinator.parent = self
            view.textContainerInset = UIEdgeInsets(insets)
            view.accessibilityLabel = placeholder
            view.accessibilityHint = invalidMessage
            if view.text != text { view.text = text }
            Self.paint(view, font: font, strokeWidth: strokeWidth, textColor: textColor)
        }

        /// The text view's face and colour, and its synthesised bold
        /// (review R5): on what is there and on what is typed next.
        static func paint(_ view: UITextView, font: UIFont, strokeWidth: CGFloat, textColor: UIColor) {
            view.font = font
            view.textColor = textColor
            let stroke = funnelFakeBoldAttributes(strokePercent: strokeWidth, color: textColor)
            view.typingAttributes.merge(stroke) { $1 }
            view.textStorage.addAttributes(stroke, range: NSRange(location: 0, length: view.textStorage.length))
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: FunnelUIKitTextArea

            init(_ parent: FunnelUIKitTextArea) { self.parent = parent }

            func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
            func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
            func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
        }
    }

#endif

#if canImport(AppKit) && !canImport(UIKit)

    /// The AppKit font a macOS field's text draws in — `funnelUIFont`'s rule.
    func funnelNSFont(size: CGFloat, weight: Int, family: String?, fonts: FunnelSessionFonts) -> NSFont {
        if let face = fonts.face(family, weight: weight, italic: false) {
            return funnelUploadedCTFont(face, size: size) as NSFont
        }
        let w = NSFont.Weight(rawValue: funnelCSSWeight(nearest: weight).trait)
        guard let family = funnelResolvedFontFamily(family) else { return .systemFont(ofSize: size, weight: w) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: w],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: w)
    }

    /// The macOS field for an uploaded family drawn heavier than any face
    /// it has (review R5): SwiftUI's `TextField` cannot carry the glyph
    /// stroke that synthesises the bold, an `NSTextField` can. Every other
    /// macOS field stays the SwiftUI one.
    struct FunnelAppKitField: NSViewRepresentable {
        let placeholder: String
        let font: NSFont
        /// Synthesised bold (`funnelFakeBoldStrokePercent`).
        let strokeWidth: CGFloat
        let textColor: NSColor
        let mutedColor: NSColor
        @Binding var text: String
        let invalidMessage: String?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSTextField {
            let field = Self.make()
            field.delegate = context.coordinator
            return field
        }

        /// A borderless, backgroundless single-line field: the box is the
        /// SwiftUI one around it.
        static func make() -> NSTextField {
            let field = NSTextField(string: "")
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            context.coordinator.parent = self
            Self.paint(
                field, text: text, placeholder: placeholder, font: font, strokeWidth: strokeWidth,
                textColor: textColor, mutedColor: mutedColor)
            field.setAccessibilityLabel(placeholder)
            field.setAccessibilityHelp(invalidMessage)
        }

        /// The field's text, placeholder, face and colours, stroked. While
        /// the field is edited its field editor draws the text, so the
        /// stroke goes on the editor's text and typing attributes too.
        static func paint(
            _ field: NSTextField, text: String, placeholder: String, font: NSFont, strokeWidth: CGFloat,
            textColor: NSColor, mutedColor: NSColor
        ) {
            let attributes = Self.attributes(font: font, strokeWidth: strokeWidth, color: textColor)
            field.font = font
            field.textColor = textColor
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder, attributes: Self.attributes(font: font, strokeWidth: strokeWidth, color: mutedColor))
            if let editor = field.currentEditor() as? NSTextView {
                if editor.string != text { editor.string = text }
                stroke(editor, attributes)
            } else {
                let value = NSAttributedString(string: text, attributes: attributes)
                if !field.attributedStringValue.isEqual(to: value) { field.attributedStringValue = value }
            }
        }

        static func attributes(font: NSFont, strokeWidth: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
            funnelFakeBoldAttributes(strokePercent: strokeWidth, color: color)
                .merging([.font: font, .foregroundColor: color]) { $1 }
        }

        /// Strokes what a field editor shows and what is typed into it.
        static func stroke(_ editor: NSTextView, _ attributes: [NSAttributedString.Key: Any]) {
            editor.typingAttributes.merge(attributes) { $1 }
            editor.textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: editor.string.utf16.count))
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: FunnelAppKitField

            init(_ parent: FunnelAppKitField) { self.parent = parent }

            func controlTextDidBeginEditing(_ notification: Notification) {
                guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
                FunnelAppKitField.stroke(
                    editor,
                    FunnelAppKitField.attributes(font: parent.font, strokeWidth: parent.strokeWidth, color: parent.textColor))
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                parent.text = field.stringValue
            }
        }
    }

    /// The macOS long-text field for a synthesised bold (review R5): an
    /// `NSTextView`, which carries the glyph stroke `TextEditor` cannot.
    struct FunnelAppKitTextArea: NSViewRepresentable {
        let font: NSFont
        /// Synthesised bold (`funnelFakeBoldStrokePercent`).
        let strokeWidth: CGFloat
        let textColor: NSColor
        let placeholder: String
        @Binding var text: String
        let invalidMessage: String?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            scroll.drawsBackground = false
            if let view = scroll.documentView as? NSTextView {
                view.drawsBackground = false
                view.isRichText = false
                view.textContainer?.lineFragmentPadding = 0
                view.delegate = context.coordinator
                view.string = text
            }
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.parent = self
            guard let view = scroll.documentView as? NSTextView else { return }
            if view.string != text { view.string = text }
            Self.paint(view, font: font, strokeWidth: strokeWidth, textColor: textColor)
            view.setAccessibilityLabel(placeholder)
            view.setAccessibilityHelp(invalidMessage)
        }

        /// The text view's face and colour, stroked: what is there and
        /// what is typed next.
        static func paint(_ view: NSTextView, font: NSFont, strokeWidth: CGFloat, textColor: NSColor) {
            view.font = font
            view.textColor = textColor
            FunnelAppKitField.stroke(view, FunnelAppKitField.attributes(font: font, strokeWidth: strokeWidth, color: textColor))
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: FunnelAppKitTextArea

            init(_ parent: FunnelAppKitTextArea) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                parent.text = view.string
            }
        }
    }

#endif
