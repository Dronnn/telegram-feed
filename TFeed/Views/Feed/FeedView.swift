import SwiftUI

struct FeedView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "doc.richtext")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Feed View")
                    .font(.title2.weight(.semibold))

                Text("The feed will be implemented in Phase 3.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Settings will be implemented in Phase 6
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}
