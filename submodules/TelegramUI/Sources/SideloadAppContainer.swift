import Foundation

// A build re-signed with a free Apple ID runs under a different bundle id, so "group.<bundle id>"
// is not its App Group and the app would stop at launch. AltStore lists the groups it assigned
// in ALTAppGroups. Otherwise the app keeps its data privately: app extensions cannot read it.
func sideloadAppContainerUrl() -> URL? {
    if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
        for group in groups {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
    }
    guard let supportUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    let url = supportUrl.appendingPathComponent("telegram-sideload", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        return nil
    }
    return url
}
