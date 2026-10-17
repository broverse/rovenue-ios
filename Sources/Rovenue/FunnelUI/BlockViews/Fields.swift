//  Fields.swift — the one field box every text, number, date and contact
//  field draws (spec D1), the SwiftUI twin of `fieldStyle` in the web's
//  `blocks/questions.tsx`.
//
//  The box is a `card` fill, a `borderWidth` hairline in `border` and
//  `cardRadius`; focused, the border is `selectedBorderWidth` in `accent`.
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
    /// The field box around an input that fills it.
    func funnelFieldBox(_ look: RenderLook, focused: Bool, minHeight: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
        return self
            .frame(maxWidth: .infinity, minHeight: CGFloat(minHeight))
            .background(shape.fill(look.cardColor))
            .overlay(
                shape.strokeBorder(
                    focused ? look.accentColor : look.borderColor,
                    lineWidth: CGFloat(focused ? look.selectedBorderWidth : look.borderWidth))
                .allowsHitTesting(false))
    }
}

/// A single-line field: short text, email, phone, number, date and each
/// contact field.
struct FunnelField: View {
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

    @State private var focused = false

    var body: some View {
        input_
            .funnelFieldBox(look, focused: focused, minHeight: look.fieldMinHeight)
    }

    @ViewBuilder
    private var input_: some View {
        #if canImport(UIKit)
            FunnelUIKitField(
                placeholder: effectivePlaceholder,
                font: funnelUIFont(size: rowText.primary, weight: look.textWeight, family: rowText.family),
                textColor: UIColor(funnelColor(color) ?? look.textColor),
                mutedColor: UIColor(look.mutedColor),
                insets: fieldInsets(look),
                lineBox: funnelLineBox(look, size: rowText.primary),
                trailingGap: CGFloat(look.indicatorGap),
                trailing: trailing,
                input: input,
                text: $text,
                focused: $focused,
                date: date,
                onDate: onDate)
        #else
            HStack(spacing: CGFloat(look.indicatorGap)) {
                TextField("", text: $text, prompt: Text(effectivePlaceholder).foregroundColor(look.mutedColor))
                    .textFieldStyle(.plain)
                    .font(rowText.primaryFont(weight: look.textWeight))
                    .ifLet(funnelColor(color)) { $0.foregroundColor($1) }
                if case .suffix(let s) = trailing {
                    Text(s).font(rowText.primaryFont(weight: look.textWeight)).foregroundColor(look.mutedColor)
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

    @State private var focused = false

    var body: some View {
        let insets = fieldInsets(look)
        ZStack(alignment: .topLeading) {
            #if canImport(UIKit)
                FunnelUIKitTextArea(
                    placeholder: placeholder,
                    font: funnelUIFont(
                        size: rowText.primary, weight: look.textWeight, family: rowText.family),
                    textColor: UIColor(funnelColor(color) ?? look.textColor),
                    insets: insets,
                    text: $text,
                    focused: $focused)
            #else
                TextEditor(text: $text)
                    .font(rowText.primaryFont(weight: look.textWeight))
                    .padding(insets)
            #endif
            if text.isEmpty {
                Text(placeholder)
                    .font(rowText.primaryFont(weight: look.textWeight))
                    .foregroundColor(look.mutedColor)
                    .padding(insets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: CGFloat(look.longTextMinHeight))
        .funnelFieldBox(look, focused: focused, minHeight: look.longTextMinHeight)
    }
}

#if canImport(UIKit)

    /// The UIKit font a field's text draws in: the authored family when the
    /// device has it, the system face otherwise — `funnelFont`'s rule.
    func funnelUIFont(size: CGFloat, weight: Int, family: String?) -> UIFont {
        // `UIFont.Weight`'s raw value IS the CoreText trait the one weight
        // table carries, so the row's trait is the UIKit weight.
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
            field.font = font
            field.textColor = textColor
            // The placeholder is the field's accessible name too: a field
            // needs one, and this is the only copy the author gave it.
            field.accessibilityLabel = placeholder
            field.attributedPlaceholder = NSAttributedString(
                string: placeholder, attributes: [.foregroundColor: mutedColor, .font: font])
            if let label = field.rightView as? UILabel {
                label.font = font
                label.textColor = mutedColor
            } else if let image = field.rightView as? UIImageView {
                image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                    pointSize: font.pointSize)
                image.tintColor = mutedColor
            }
            if input != .date, field.text != text { field.text = text }
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
        let textColor: UIColor
        let insets: EdgeInsets
        @Binding var text: String
        @Binding var focused: Bool

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
            view.font = font
            view.textColor = textColor
            view.accessibilityLabel = placeholder
            if view.text != text { view.text = text }
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
