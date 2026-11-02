import Foundation
import SwiftSignalKit
import TelegramCore

// Reads one Telegram file through the media cache, downloading what is not there yet. The file
// reaches the LAN only through the server this source is given to, and only for this session.
final class TelegramCastFileByteSource: TelegramCastByteSource {
    private static let readTimeout: Double = 60.0

    let contentType: String
    let size: Int64

    private let engine: TelegramEngine
    private let file: FileMediaReference
    private let userLocation: MediaResourceUserLocation

    init(engine: TelegramEngine, file: FileMediaReference, userLocation: MediaResourceUserLocation, size: Int64, contentType: String) {
        self.engine = engine
        self.file = file
        self.userLocation = userLocation
        self.size = size
        self.contentType = contentType
    }

    func read(range: Range<Int64>, completion: @escaping (Data?) -> Void) -> () -> Void {
        let fetch = self.engine.resources.fetch(
            reference: self.file.resourceReference(self.file.media.resource),
            userLocation: self.userLocation,
            userContentType: .video,
            range: (range, .elevated)
        ).start()

        let resource = EngineMediaResource(self.file.media.resource)
        let data = (self.engine.resources.rangeData(resource: resource, size: self.size, range: range)
        |> filter { _, isComplete in
            return isComplete
        }
        |> take(1)
        |> map { data, _ -> Data? in
            return data
        }
        |> timeout(TelegramCastFileByteSource.readTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))).start(next: { data in
            completion(data)
        })

        return {
            fetch.dispose()
            data.dispose()
        }
    }
}

public enum TelegramCastMediaProvider {
    // Container types Cast's documented media support includes. A file of any other type
    // (mkv, avi, ...) stays local rather than failing on the receiver.
    public static func contentType(mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "video/mp4", "video/quicktime", "video/x-m4v":
            return "video/mp4"
        case "video/webm":
            return "video/webm"
        default:
            return nil
        }
    }

    public static func contentType(url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v":
            return "video/mp4"
        case "webm":
            return "video/webm"
        case "m3u8":
            return "application/x-mpegurl"
        default:
            return nil
        }
    }

    public static func media(engine: TelegramEngine, file: FileMediaReference, userLocation: MediaResourceUserLocation, title: String?, duration: Double?) -> TelegramCastMedia? {
        guard let size = file.media.size, size > 0, let contentType = TelegramCastMediaProvider.contentType(mimeType: file.media.mimeType) else {
            return nil
        }
        let source = TelegramCastFileByteSource(engine: engine, file: file, userLocation: userLocation, size: size, contentType: contentType)
        return TelegramCastMedia(source: .local(source), title: title, duration: duration)
    }

    public static func media(externalUrl: String, title: String?, duration: Double?) -> TelegramCastMedia? {
        guard let url = URL(string: externalUrl), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let contentType = TelegramCastMediaProvider.contentType(url: url) else {
            return nil
        }
        return TelegramCastMedia(source: .remote(url: url, contentType: contentType), title: title, duration: duration)
    }
}
