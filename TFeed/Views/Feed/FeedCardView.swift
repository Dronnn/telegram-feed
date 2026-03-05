import SwiftUI
import TDLibKit

struct FeedCardView: View {
    let item: FeedItem
    var onChannelTap: (() -> Void)? = nil
    var onPostLinkTap: ((URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            Button {
                onChannelTap?()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Text(String(item.channelTitle.prefix(1)).uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                    Text(item.channelTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.label))

                    Text("\u{00B7}")
                        .foregroundStyle(.secondary)

                    Text(relativeTime(for: item.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Text content
            if let formattedText = item.formattedText, !formattedText.text.isEmpty {
                FormattedTextView(formattedText: formattedText, onTelegramLinkTap: onPostLinkTap)
            }

            // Media
            if let mediaInfo = item.mediaInfo {
                MediaContentView(mediaInfo: mediaInfo)
            }

            // Reactions
            ReactionsBarView(reactions: item.reactions)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
