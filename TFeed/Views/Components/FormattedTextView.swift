import SwiftUI
import TDLibKit

struct FormattedTextView: View {
    let formattedText: FormattedText
    var onTelegramLinkTap: ((URL) -> Bool)? = nil
    @State private var revealedSpoilers: Set<Int> = []

    var body: some View {
        Text(buildAttributedString())
            .font(.body)
            .foregroundStyle(Color(.label))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "spoiler", let index = Int(url.host() ?? "") {
                    revealedSpoilers.insert(index)
                    return .handled
                }
                if isTelegramLink(url), let onTelegramLinkTap {
                    return onTelegramLinkTap(url) ? .handled : .systemAction
                }
                return .systemAction
            })
    }

    private func buildAttributedString() -> AttributedString {
        let fullText = formattedText.text
        guard !fullText.isEmpty else { return AttributedString() }

        let utf16 = fullText.utf16
        var attributed = AttributedString(fullText)

        for (entityIndex, entity) in formattedText.entities.enumerated() {
            let offset = entity.offset
            let length = entity.length

            guard offset >= 0, length > 0, offset + length <= utf16.count else { continue }

            let utf16Start = utf16.index(utf16.startIndex, offsetBy: offset)
            let utf16End = utf16.index(utf16Start, offsetBy: length)

            guard let substringStart = String.Index(utf16Start, within: fullText),
                  let substringEnd = String.Index(utf16End, within: fullText) else { continue }

            let attrStart = AttributedString.Index(substringStart, within: attributed)
            let attrEnd = AttributedString.Index(substringEnd, within: attributed)

            guard let start = attrStart, let end = attrEnd, start < end else { continue }

            let range = start ..< end

            switch entity.type {
            case .textEntityTypeBold:
                attributed[range].inlinePresentationIntent = .stronglyEmphasized

            case .textEntityTypeItalic:
                attributed[range].inlinePresentationIntent = .emphasized

            case .textEntityTypeUnderline:
                attributed[range].underlineStyle = .single

            case .textEntityTypeStrikethrough:
                attributed[range].strikethroughStyle = .single

            case .textEntityTypeCode:
                attributed[range].font = .system(.body, design: .monospaced)

            case .textEntityTypePre:
                attributed[range].font = .system(.body, design: .monospaced)
                attributed[range].backgroundColor = Color(.tertiarySystemFill)

            case .textEntityTypeTextUrl(let textUrl):
                if let url = URL(string: textUrl.url) {
                    attributed[range].link = url
                }

            case .textEntityTypeUrl:
                let urlString = String(fullText[substringStart ..< substringEnd])
                if let url = URL(string: urlString) {
                    attributed[range].link = url
                }

            case .textEntityTypeSpoiler:
                if revealedSpoilers.contains(entityIndex) {
                    // Revealed — show normal text
                    break
                } else {
                    // Hidden — obscure text
                    let spoilerURL = URL(string: "spoiler://\(entityIndex)")!
                    attributed[range].foregroundColor = .clear
                    attributed[range].backgroundColor = Color(.tertiaryLabel)
                    attributed[range].link = spoilerURL
                }

            case .textEntityTypeMention:
                attributed[range].foregroundColor = .accentColor

            case .textEntityTypeMentionName:
                attributed[range].foregroundColor = .accentColor

            default:
                break
            }
        }

        return attributed
    }

    private func isTelegramLink(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "t.me" || host == "telegram.me" || host == "telegram.dog"
    }
}
