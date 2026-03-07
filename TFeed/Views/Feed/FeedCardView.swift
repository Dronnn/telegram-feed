import SwiftUI

struct FeedCardView: View {
    let item: FeedItem
    var isRead: Bool = true
    var onChannelTap: (() -> Void)? = nil
    var onTelegramLinkTap: ((FeedItemID) -> Void)? = nil
    var onPostReferenceTap: ((FeedItem.PostReference) -> Void)? = nil

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

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(relativeTime(for: item.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if isRead {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }

                        Text(exactTimestamp(for: item.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Text content
            if let formattedText = item.formattedText, !formattedText.text.isEmpty {
                FormattedTextView(formattedText: formattedText, onTelegramLinkTap: { url in
                    guard let target = telegramTarget(from: url) else { return false }
                    onTelegramLinkTap?(target)
                    return true
                })
            }

            // Media
            if let mediaInfo = item.mediaInfo {
                MediaContentView(mediaInfo: mediaInfo)
            }

            // Reactions
            ReactionsBarView(reactions: item.reactions)

            Button {
                onPostReferenceTap?(item.postReference)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.semibold))

                    Text(item.postReference.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func telegramTarget(from url: URL) -> FeedItemID? {
        nil
    }
}
