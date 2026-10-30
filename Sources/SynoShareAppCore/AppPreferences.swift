import Foundation

/// Non-secret settings remembered between launches. The password is never stored here.
public struct AppPreferences: @unchecked Sendable {
    enum Key {
        static let shareURL = "shareURL"
        static let destination = "destinationPath"
        static let preventSleep = "preventSleep"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var shareURL: String {
        get { defaults.string(forKey: Key.shareURL) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.shareURL) }
    }

    public var destination: URL? {
        get { defaults.string(forKey: Key.destination).map { URL(filePath: $0, directoryHint: .isDirectory) } }
        nonmutating set { defaults.set(newValue?.path, forKey: Key.destination) }
    }

    public var preventSleep: Bool {
        get { defaults.object(forKey: Key.preventSleep) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.preventSleep) }
    }
}
