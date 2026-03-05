import SwiftUI

struct FeedCardView: View {
    let item: FeedItem
    var onChannelTap: (() -> Void)? = nil

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

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Text content
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(Color(.label))
            }

            // Media
            if let mediaInfo = item.mediaInfo {
                MediaContentView(mediaInfo: mediaInfo)
            }

            // Reactions
            if !item.reactions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.reactions, id: \.emoji) { reaction in
                        HStack(spacing: 4) {
                            Text(reaction.emoji)
                            Text("\(reaction.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.date))
        let interval = Date.now.timeIntervalSince(date)

        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
