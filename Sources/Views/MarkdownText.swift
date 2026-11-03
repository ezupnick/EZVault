import SwiftUI

/// Lightweight Markdown renderer. Splits text into blocks (headings, lists, code
/// fences, quotes, rules) and renders inline formatting with AttributedString.
/// Links — including `ezvault://note/…` citations — render tappable via openURL.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Block.parse(text).enumerated()), id: \.offset) { item in
                item.element.view
            }
        }
    }
}

private enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(String)
    case rule

    @ViewBuilder var view: some View {
        switch self {
        case .heading(let level, let t):
            inline(t).font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.bold()))
        case .paragraph(let t):
            inline(t)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•"); inline(item.element)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(item.offset + 1).").foregroundStyle(.secondary); inline(item.element)
                    }
                }
            }
        case .quote(let t):
            inline(t)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(.secondary.opacity(0.4))
                }
        case .code(let c):
            Text(c)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        Text(Block.attributed(s))
    }

    // MARK: Parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); i += 1; continue }
            if let level = headingLevel(line) {
                flush()
                blocks.append(.heading(level: level, text: String(line.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))))
                i += 1; continue
            }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); i += 1; continue }
            if isBullet(line) {
                flush()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                blocks.append(.bullet(items)); continue
            }
            if let _ = orderedPrefix(line) {
                flush()
                var items: [String] = []
                while i < lines.count, let p = orderedPrefix(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(p)))
                    i += 1
                }
                blocks.append(.ordered(items)); continue
            }
            paragraph.append(line); i += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line { if ch == "#" { n += 1 } else { break } }
        return (n >= 1 && n <= 6 && line.dropFirst(n).first == " ") ? n : nil
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// Returns the length of an ordered-list marker like "1. " if present.
    private static func orderedPrefix(_ line: String) -> Int? {
        var digits = 0
        for ch in line { if ch.isNumber { digits += 1 } else { break } }
        guard digits > 0 else { return nil }
        let rest = line.dropFirst(digits)
        return (rest.hasPrefix(". ") || rest.hasPrefix(") ")) ? digits + 2 : nil
    }

    private static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
