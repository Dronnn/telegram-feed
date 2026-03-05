import Foundation

enum Preferences {
    private static let selectedChannelsKey = "preferences.selectedChannelIDs"

    static func saveSelectedChannels(_ ids: Set<Int64>) {
        let array = ids.map { $0 }
        UserDefaults.standard.set(array, forKey: selectedChannelsKey)
    }

    static func loadSelectedChannels() -> Set<Int64> {
        guard let array = UserDefaults.standard.object(forKey: selectedChannelsKey) as? [Int64] else {
            return []
        }
        return Set(array)
    }
}
