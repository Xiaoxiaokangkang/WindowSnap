import Foundation

final class LayoutPreferenceStore {
    private let defaults = UserDefaults.standard
    private let key = "activeColumnCount.v1"

    var columnCount: Int {
        get {
            let saved = defaults.integer(forKey: key)
            return (5...8).contains(saved) ? saved : 6
        }
        set {
            guard (5...8).contains(newValue) else { return }
            defaults.set(newValue, forKey: key)
        }
    }
}
