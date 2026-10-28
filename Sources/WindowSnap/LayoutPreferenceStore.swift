import Foundation

final class LayoutPreferenceStore {
    static let supportedColumnCounts = Array(4...8)

    private let defaults = UserDefaults.standard
    private let key = "activeColumnCount.v1"

    var columnCount: Int {
        get {
            let saved = defaults.integer(forKey: key)
            return Self.supportedColumnCounts.contains(saved) ? saved : 6
        }
        set {
            guard Self.supportedColumnCounts.contains(newValue) else { return }
            defaults.set(newValue, forKey: key)
        }
    }
}
