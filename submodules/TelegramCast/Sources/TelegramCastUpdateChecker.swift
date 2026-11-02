import Foundation

// Tells the user that a newer build was published. It only informs: iOS installs an app through
// the channel that signed it (TestFlight, ad hoc, ...), so nothing here downloads or installs.
public struct TelegramCastAvailableUpdate: Decodable, Equatable {
    public let version: String
    public let build: Int
    public let releaseDate: String
    public let notes: String
    public let url: String?
}

public enum TelegramCastUpdateChecker {
    static let feedInfoPlistKey = "TelegramCastUpdateFeedURL"

    public static func newerUpdate(feed: Data, installedBuild: Int) -> TelegramCastAvailableUpdate? {
        guard let update = try? JSONDecoder().decode(TelegramCastAvailableUpdate.self, from: feed), update.build > installedBuild else {
            return nil
        }
        return update
    }

    // No feed configured (the default) means no request is made. completion runs on the main
    // thread and only when an update exists.
    public static func check(completion: @escaping (TelegramCastAvailableUpdate) -> Void) {
        guard let value = Bundle.main.object(forInfoDictionaryKey: TelegramCastUpdateChecker.feedInfoPlistKey) as? String, let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            return
        }
        guard let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, let installedBuild = Int(buildString) else {
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15.0
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let update = TelegramCastUpdateChecker.newerUpdate(feed: data, installedBuild: installedBuild) else {
                return
            }
            DispatchQueue.main.async {
                completion(update)
            }
        }.resume()
    }
}
