import Foundation

/// Một "client" giả danh app YouTube để xin link phát nhạc trực tiếp.
/// Thông số lấy từ providers/innertube của Mochy Music (GPL-3.0) và được viết lại bằng Swift.
struct PlayerClient {
    let name: String
    let clientId: String
    let version: String
    let userAgent: String
    let origin: String
    let osName: String?
    let osVersion: String?
    let deviceMake: String?
    let deviceModel: String?
    let androidSdkVersion: String?
    var clientScreen: String? = nil
    var platform: String? = nil
    var apiFormat: String = "1"
    var ownVisitor: Bool = false

    var contextClient: [String: Any] {
        var c: [String: Any] = [
            "clientName": name,
            "clientVersion": version,
            "hl": "en",
            "gl": "US"
        ]
        if let v = osName { c["osName"] = v }
        if let v = osVersion { c["osVersion"] = v }
        if let v = deviceMake { c["deviceMake"] = v }
        if let v = deviceModel { c["deviceModel"] = v }
        if let v = androidSdkVersion { c["androidSdkVersion"] = v }
        if let v = clientScreen { c["clientScreen"] = v; c["utcOffsetMinutes"] = 0 }
        if let v = platform { c["platform"] = v }
        return c
    }

    static let androidVR161 = PlayerClient(
        name: "ANDROID_VR", clientId: "28", version: "1.61.48",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)",
        origin: "https://music.youtube.com",
        osName: "Android", osVersion: "12", deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: "32")

    static let androidVR143 = PlayerClient(
        name: "ANDROID_VR", clientId: "28", version: "1.43.32",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
        origin: "https://music.youtube.com",
        osName: "Android", osVersion: "12", deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: "32")

    /// Client "VISIONOS": từ giữa tháng 8/2026 YouTube chỉ còn cho ANDROID_VR tải khoảng 1 MB đầu (bắt buộc token),
    /// nên nhạc dừng ở khoảng 59 giây. VISIONOS vẫn trả link âm thanh AAC đầy đủ, không cần token.
    /// Thông số lấy từ yt-dlp (INNERTUBE_CLIENTS["visionos"]).
    static func visionOS(origin: String) -> PlayerClient {
        // Thông số y hệt Mochy Music (YouTubeClient.VISIONOS): app YouTube trên Apple Vision Pro, có visitor id riêng.
        return PlayerClient(
            name: "VISIONOS", clientId: "101", version: "1.04",
            userAgent: "com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; US)",
            origin: origin,
            osName: "visionOS", osVersion: "26.6.0.23O770", deviceMake: "Apple", deviceModel: "RealityDevice17,1", androidSdkVersion: nil,
            clientScreen: "WATCH", platform: "MOBILE", apiFormat: "2", ownVisitor: true)
    }

    static let ios = PlayerClient(
        name: "IOS", clientId: "5", version: "21.03.1",
        userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
        origin: "https://music.youtube.com",
        osName: "iPhone", osVersion: "18.2.22C152", deviceMake: "Apple", deviceModel: "iPhone16,2", androidSdkVersion: nil)
}

/// Gọi API nội bộ của YouTube Music: tìm bài hát và lấy link âm thanh.
final class InnerTube {
    static let shared = InnerTube()
    /// Bật khi AVPlayer không mở được âm thanh AAC riêng: chuyển sang luồng ghép hình + tiếng (itag 18).
    static var preferMuxed = false

    private let apiBase = "https://music.youtube.com/youtubei/v1/"
    private let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    private let webRemixVersion = "1.20260707.12.00"
    private let songFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    // MARK: - HTTP

    private func postJSON(_ urlString: String,
                          headers: [String: String],
                          body: [String: Any],
                          completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(MochyError.badResponse("URL sai")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
        }
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else {
                completion(.failure(MochyError.badResponse("không có dữ liệu")))
                return
            }
            if code < 200 || code >= 300 {
                let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                completion(.failure(MochyError.http(code, url.host ?? "", snippet)))
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = object as? [String: Any] {
                    completion(.success(dict))
                } else {
                    completion(.failure(MochyError.badResponse("không phải JSON object")))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Tìm kiếm

    func search(_ query: String, completion: @escaping (Result<[Song], Error>) -> Void) {
        let client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": webRemixVersion,
            "hl": "vi",
            "gl": "VN"
        ]
        let body: [String: Any] = [
            "context": ["client": client],
            "query": query,
            "params": songFilter
        ]
        let headers: [String: String] = [
            "X-Goog-Api-Format-Version": "1",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": webRemixVersion,
            "X-Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "User-Agent": webUserAgent
        ]
        postJSON(apiBase + "search?prettyPrint=false", headers: headers, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let json):
                    completion(.success(InnerTube.parseSongs(json)))
                }
            }
        }
    }

    // MARK: - Khám phá (browse)

    func browse(_ browseId: String, formData: [String: Any]? = nil,
                completion: @escaping (Result<[Shelf], Error>) -> Void) {
        let client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": webRemixVersion,
            "hl": "vi",
            "gl": "VN"
        ]
        var body: [String: Any] = [
            "context": ["client": client],
            "browseId": browseId
        ]
        if let formData = formData { body["formData"] = formData }
        let headers: [String: String] = [
            "X-Goog-Api-Format-Version": "1",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": webRemixVersion,
            "X-Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "User-Agent": webUserAgent
        ]
        postJSON(apiBase + "browse?prettyPrint=false", headers: headers, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let json):
                    completion(.success(InnerTube.parseShelves(json)))
                }
            }
        }
    }

    // MARK: - Lấy link phát

    func resolveStream(videoId: String, completion: @escaping (Result<StreamInfo, Error>) -> Void) {
        // Mỗi link được kiểm tra bằng cách xin byte cuối tệp (giống Mochy Music): link bị cắt sẽ bị từ chối ở đó,
        // khi đó chuyển sang client kế tiếp. Nếu không client nào qua kiểm tra, dùng link đầu tiên lấy được.
        let clients: [PlayerClient] = [PlayerClient.visionOS(origin: "https://www.youtube.com"),
                                       PlayerClient.androidVR161, PlayerClient.androidVR143,
                                       PlayerClient.ios]
        attempt(videoId: videoId, clients: clients, index: 0, notes: [], fallback: nil, completion: completion)
    }

    private func attempt(videoId: String,
                         clients: [PlayerClient],
                         index: Int,
                         notes: [String],
                         fallback: StreamInfo?,
                         completion: @escaping (Result<StreamInfo, Error>) -> Void) {
        if index >= clients.count {
            if var fb = fallback {
                fb.unverified = true
                DispatchQueue.main.async { completion(.success(fb)) }
                return
            }
            let message = "Không lấy được link nhạc:\n" + notes.joined(separator: "\n")
            DispatchQueue.main.async { completion(.failure(MochyError.noStream(message))) }
            return
        }
        let client = clients[index]
        if client.ownVisitor {
            visitorId(for: client) { [weak self] visitor in
                self?.send(videoId: videoId, client: client, visitor: visitor, clients: clients, index: index, notes: notes, fallback: fallback, completion: completion)
            }
        } else {
            send(videoId: videoId, client: client, visitor: nil, clients: clients, index: index, notes: notes, fallback: fallback, completion: completion)
        }
    }

    private var visitorCache: [String: String] = [:]
    private let visitorLock = NSLock()

    /// Xin visitor id riêng cho client (giống mintVisitorId của Mochy), lưu lại dùng tiếp.
    private func visitorId(for client: PlayerClient, completion: @escaping (String?) -> Void) {
        visitorLock.lock(); let cached = visitorCache[client.name]; visitorLock.unlock()
        if let cached = cached { completion(cached); return }
        let body: [String: Any] = ["context": ["client": client.contextClient]]
        let headers: [String: String] = [
            "X-Goog-Api-Format-Version": client.apiFormat,
            "X-YouTube-Client-Name": client.clientId,
            "X-YouTube-Client-Version": client.version,
            "User-Agent": client.userAgent
        ]
        postJSON(client.origin + "/youtubei/v1/visitor_id?prettyPrint=false", headers: headers, body: body) { [weak self] result in
            var found: String?
            if case .success(let json) = result {
                found = InnerTube.dig(json, ["responseContext", "visitorData"]) as? String
            }
            if let v = found, let self = self {
                self.visitorLock.lock(); self.visitorCache[client.name] = v; self.visitorLock.unlock()
            }
            completion(found)
        }
    }

    private func send(videoId: String, client: PlayerClient, visitor: String?,
                      clients: [PlayerClient], index: Int, notes: [String], fallback: StreamInfo?,
                      completion: @escaping (Result<StreamInfo, Error>) -> Void) {
        var ctx = client.contextClient
        if let v = visitor { ctx["visitorData"] = v }
        let body: [String: Any] = [
            "context": ["client": ctx],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        var headers: [String: String] = [
            "X-Goog-Api-Format-Version": client.apiFormat,
            "X-YouTube-Client-Name": client.clientId,
            "X-YouTube-Client-Version": client.version,
            "User-Agent": client.userAgent
        ]
        if let v = visitor { headers["X-Goog-Visitor-Id"] = v }
        let url = client.origin + "/youtubei/v1/player?prettyPrint=false"
        postJSON(url, headers: headers, body: body) { result in
            var next = notes
            switch result {
            case .failure(let error):
                next.append("• \(client.name): \(error.localizedDescription)")
            case .success(let json):
                if let info = InnerTube.pickStream(json, client: client) {
                    if self.verifyFullLength(info) {
                        DispatchQueue.main.async { completion(.success(info)) }
                        return
                    }
                    next.append("• \(client.name): link bị cắt giữa chừng")
                    self.attempt(videoId: videoId, clients: clients, index: index + 1, notes: next,
                                 fallback: fallback ?? info, completion: completion)
                    return
                }
                next.append("• \(client.name): \(InnerTube.describePlayability(json))")
            }
            self.attempt(videoId: videoId, clients: clients, index: index + 1, notes: next, fallback: fallback, completion: completion)
        }
    }

    /// Xin đúng byte cuối của tệp: link đầy đủ trả 206/200, link bị cắt trả 403. Không biết dung lượng thì coi như đạt.
    private func verifyFullLength(_ info: StreamInfo) -> Bool {
        guard info.contentLength > 1 else { return true }
        var req = URLRequest(url: info.url)
        req.timeoutInterval = 8
        req.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(info.contentLength - 1)-\(info.contentLength - 1)", forHTTPHeaderField: "Range")
        let sem = DispatchSemaphore(value: 0)
        var ok = true
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let http = response as? HTTPURLResponse {
                ok = (200..<300).contains(http.statusCode)
            } else if error != nil {
                ok = true  // lỗi mạng tạm thời: không loại client
            }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    // MARK: - Phân tích JSON

    /// Đi theo đường dẫn khoá/chỉ số trong JSON, an toàn với dữ liệu thiếu.
    static func dig(_ root: Any?, _ path: [Any]) -> Any? {
        var current = root
        for step in path {
            if let key = step as? String {
                current = (current as? [String: Any])?[key]
            } else if let idx = step as? Int {
                if let array = current as? [Any], idx >= 0, idx < array.count {
                    current = array[idx]
                } else {
                    return nil
                }
            }
        }
        return current
    }

    private static func collectItems(_ node: Any, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                out.append(item)
                return
            }
            for (_, value) in dict {
                collectItems(value, into: &out)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectItems(value, into: &out)
            }
        }
    }

    private static func findString(_ node: Any, key: String) -> String? {
        if let dict = node as? [String: Any] {
            if let s = dict[key] as? String { return s }
            for (_, value) in dict {
                if let found = findString(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findString(value, key: key) { return found }
            }
        }
        return nil
    }

    private static func runs(_ item: [String: Any], column: Int) -> [String] {
        let path: [Any] = ["flexColumns", column, "musicResponsiveListItemFlexColumnRenderer", "text", "runs"]
        guard let list = dig(item, path) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["text"] as? String }
    }

    private static func sizedThumbnail(_ thumbs: [[String: Any]]?) -> URL? {
        guard let raw = thumbs?.last?["url"] as? String else { return nil }
        let sized = raw.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w226-h226", options: .regularExpression)
        return URL(string: sized)
    }

    private static let typeWords: Set<String> = ["Song", "Video", "Single", "EP", "Album", "Bài hát", "Đĩa đơn", "Băng đĩa"]

    /// Tìm browseId của nghệ sĩ trong một dãy "runs" (chữ có kèm liên kết).
    static func artistId(in runs: [[String: Any]]) -> String? {
        for run in runs {
            let endpoint = dig(run, ["navigationEndpoint", "browseEndpoint"]) as? [String: Any]
            guard let id = endpoint?["browseId"] as? String, id.hasPrefix("UC") else { continue }
            let page = dig(endpoint, ["browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"]) as? String
            if page == nil || page == "MUSIC_PAGE_TYPE_ARTIST" || page == "MUSIC_PAGE_TYPE_USER_CHANNEL" { return id }
        }
        return nil
    }

    fileprivate static func makeSong(fromListItem item: [String: Any]) -> Song? {
        guard let videoId = findString(item, key: "videoId") else { return nil }
        let title = runs(item, column: 0).joined()
        if title.isEmpty { return nil }
        var parts = runs(item, column: 1).filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        if let first = parts.first, typeWords.contains(first) {
            parts.removeFirst()
        }
        let artist = parts.first ?? ""
        let duration: String? = (parts.last != nil && parts.last!.contains(":")) ? parts.last : nil
        let subtitle = parts.joined(separator: " · ")
        let thumbPath: [Any] = ["thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"]
        let thumb = sizedThumbnail(dig(item, thumbPath) as? [[String: Any]])
        var song = Song(videoId: videoId, title: title, artist: artist, subtitle: subtitle, duration: duration, thumbnailURL: thumb)
        song.explicit = String(describing: item).contains("MUSIC_EXPLICIT_BADGE")
        let columnRuns = (dig(item, ["flexColumns", 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs"]) as? [[String: Any]]) ?? []
        song.artistId = artistId(in: columnRuns)
        return song
    }

    private static func makeSong(fromTwoRow item: [String: Any]) -> Song? {
        guard let videoId = dig(item, ["navigationEndpoint", "watchEndpoint", "videoId"]) as? String else { return nil }
        let titleRuns = (dig(item, ["title", "runs"]) as? [[String: Any]]) ?? []
        let title = titleRuns.compactMap { $0["text"] as? String }.joined()
        if title.isEmpty { return nil }
        let subRuns = (dig(item, ["subtitle", "runs"]) as? [[String: Any]]) ?? []
        var parts = subRuns.compactMap { $0["text"] as? String }.filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        if let first = parts.first, typeWords.contains(first) {
            parts.removeFirst()
        }
        let artist = parts.first ?? ""
        let thumbPath: [Any] = ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"]
        let thumb = sizedThumbnail(dig(item, thumbPath) as? [[String: Any]])
        var song = Song(videoId: videoId, title: title, artist: artist, subtitle: parts.joined(separator: " · "),
                        duration: nil, thumbnailURL: thumb)
        song.artistId = artistId(in: subRuns)
        return song
    }

    static func parseSongs(_ json: [String: Any]) -> [Song] {
        var items: [[String: Any]] = []
        collectItems(json, into: &items)
        var songs: [Song] = []
        var seen = Set<String>()
        for item in items {
            guard let song = makeSong(fromListItem: item), !seen.contains(song.videoId) else { continue }
            seen.insert(song.videoId)
            songs.append(song)
        }
        return songs
    }

    // MARK: - Các hàng (shelf) trên trang Khám phá / Bảng xếp hạng

    fileprivate static func collectShelves(_ node: Any, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            for key in ["musicCarouselShelfRenderer", "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicImmersiveCarouselShelfRenderer"] {
                if let shelf = dict[key] as? [String: Any] {
                    out.append(shelf)
                    return
                }
            }
            for (_, value) in dict {
                collectShelves(value, into: &out)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectShelves(value, into: &out)
            }
        }
    }

    fileprivate static func shelfTitle(_ shelf: [String: Any]) -> String {
        let paths: [[Any]] = [
            ["header", "musicCarouselShelfBasicHeaderRenderer", "title", "runs", 0, "text"],
            ["header", "musicImmersiveCarouselShelfBasicHeaderRenderer", "title", "runs", 0, "text"],
            ["title", "runs", 0, "text"]
        ]
        for path in paths {
            if let text = dig(shelf, path) as? String, !text.isEmpty { return text }
        }
        return ""
    }

    static func parseShelves(_ json: [String: Any]) -> [Shelf] {
        var rendered: [[String: Any]] = []
        collectShelves(json, into: &rendered)
        var shelves: [Shelf] = []
        for shelf in rendered {
            guard let contents = shelf["contents"] as? [Any] else { continue }
            var songs: [Song] = []
            var seen = Set<String>()
            for element in contents {
                guard let dict = element as? [String: Any] else { continue }
                var found: Song? = nil
                if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                    found = makeSong(fromListItem: item)
                } else if let item = dict["musicTwoRowItemRenderer"] as? [String: Any] {
                    found = makeSong(fromTwoRow: item)
                }
                if let song = found, !seen.contains(song.videoId) {
                    seen.insert(song.videoId)
                    songs.append(song)
                }
            }
            if songs.count >= 3 {
                shelves.append(Shelf(title: shelfTitle(shelf), songs: songs))
            }
        }
        return shelves
    }

    static func pickStream(_ json: [String: Any], client: PlayerClient) -> StreamInfo? {
        guard let streaming = json["streamingData"] as? [String: Any] else { return nil }
        var all: [[String: Any]] = []
        if let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] { all.append(contentsOf: adaptive) }
        if let muxed = streaming["formats"] as? [[String: Any]] { all.append(contentsOf: muxed) }

        func bitrate(_ f: [String: Any]) -> Int {
            return (f["averageBitrate"] as? Int) ?? (f["bitrate"] as? Int) ?? 0
        }
        func make(_ f: [String: Any], _ urlString: String, _ defaultMime: String) -> StreamInfo? {
            guard let url = URL(string: urlString) else { return nil }
            let rate = Int((f["audioSampleRate"] as? String) ?? "") ?? 0
            var info = StreamInfo(url: url, userAgent: client.userAgent,
                                  mimeType: (f["mimeType"] as? String) ?? defaultMime,
                                  clientName: client.name, bitrate: bitrate(f), sampleRate: rate)
            info.contentLength = Int64((f["contentLength"] as? String) ?? "") ?? 0
            if let ms = Double((f["approxDurationMs"] as? String) ?? "") {
                info.durationSeconds = ms / 1000
            } else if let len = Double((dig(json, ["videoDetails", "lengthSeconds"]) as? String) ?? "") {
                info.durationSeconds = len
            }
            return info
        }

        // 1) Âm thanh AAC (audio/mp4) có link trực tiếp: AVPlayer trên iOS 12 phát được.
        let anyAudio = all.filter { format in
            guard let mime = format["mimeType"] as? String else { return false }
            return mime.hasPrefix("audio/mp4") && (format["url"] as? String) != nil
        }
        // Ưu tiên AAC thường (mp4a), bỏ bản DRC / thuyết minh phụ; không còn thì dùng tất cả.
        let cleanAudio = anyAudio.filter { format in
            let mime = (format["mimeType"] as? String) ?? ""
            let isDrc = (format["isDrc"] as? Bool) ?? false
            let isDefaultTrack = ((format["audioTrack"] as? [String: Any])?["audioIsDefault"] as? Bool) ?? true
            return mime.contains("mp4a") && !isDrc && isDefaultTrack
        }
        let audio = (InnerTube.preferMuxed) ? [] : (cleanAudio.isEmpty ? anyAudio : cleanAudio)
        let wantLow = AppSettings.audioQuality == .saver
        let chosen = wantLow
            ? audio.min(by: { bitrate($0) < bitrate($1) })
            : audio.max(by: { bitrate($0) < bitrate($1) })
        if let best = chosen, let urlString = best["url"] as? String,
           var info = make(best, urlString, "audio/mp4") {
            info.videoURL = pickVideo(json, all)
            return info
        }

        // 2) Dự phòng: luồng ghép hình + tiếng (itag 18) nếu không có âm thanh riêng.
        let muxedOnly = all.filter { format in
            guard let mime = format["mimeType"] as? String else { return false }
            return mime.hasPrefix("video/mp4") && (format["url"] as? String) != nil && format["audioQuality"] != nil
        }
        if let low = muxedOnly.min(by: { bitrate($0) < bitrate($1) }),
           let urlString = low["url"] as? String, let info = make(low, urlString, "video/mp4") {
            return info
        }
        return nil
    }

    /// Luồng video-only H.264 (≤ 480p) để làm nền; bỏ qua nhạc chỉ có ảnh tĩnh (loại ATV).
    static func pickVideo(_ json: [String: Any], _ all: [[String: Any]]) -> URL? {
        let type = (dig(json, ["videoDetails", "musicVideoType"]) as? String) ?? ""
        if type == "MUSIC_VIDEO_TYPE_ATV" || type == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return nil }
        let candidates = all.filter { f in
            guard let mime = f["mimeType"] as? String, (f["url"] as? String) != nil else { return false }
            let h = (f["height"] as? Int) ?? 0
            return mime.hasPrefix("video/mp4") && mime.contains("avc1") && f["audioQuality"] == nil && h > 0 && h <= 480
        }
        let best = candidates.max { a, b in
            ((a["height"] as? Int) ?? 0) < ((b["height"] as? Int) ?? 0)
        }
        if let urlString = best?["url"] as? String { return URL(string: urlString) }
        return nil
    }

    static func describePlayability(_ json: [String: Any]) -> String {
        let status = (dig(json, ["playabilityStatus", "status"]) as? String) ?? "?"
        let reason = (dig(json, ["playabilityStatus", "reason"]) as? String) ?? ""
        if json["streamingData"] == nil {
            return reason.isEmpty ? "trạng thái \(status), không có luồng" : "\(status): \(reason)"
        }
        return "có luồng nhưng không có link trực tiếp (cần giải mã chữ ký)"
    }
}

// MARK: - Playlist, nghệ sĩ, album (YouTube Music)

/// Một thẻ (album, đĩa đơn, nghệ sĩ liên quan…) trên trang nghệ sĩ.
struct BrowseCard {
    let title: String
    let subtitle: String
    let thumbnail: URL?
    let browseId: String
}

struct ArtistSection {
    let title: String
    let cards: [BrowseCard]
}

struct ArtistPage {
    var name: String
    var thumbnail: URL?
    var songs: [Song]
    var sections: [ArtistSection]
}

struct AlbumPage {
    var title: String
    var artist: String
    var thumbnail: URL?
    var songs: [Song]
}

extension InnerTube {
    /// Gọi một endpoint YouTube Music (browse, search…) bằng client WEB_REMIX; kết quả trả về trên main.
    func music(_ endpoint: String, extra: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": webRemixVersion, "hl": "vi", "gl": "VN"]
        var body: [String: Any] = ["context": ["client": client]]
        for (key, value) in extra { body[key] = value }
        let headers: [String: String] = [
            "X-Goog-Api-Format-Version": "1", "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": webRemixVersion,
            "X-Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/", "User-Agent": webUserAgent
        ]
        postJSON(apiBase + endpoint + "?prettyPrint=false", headers: headers, body: body) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func findToken(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any], let token = command["token"] as? String { return token }
            for (_, value) in dict { if let found = findToken(value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = findToken(value) { return found } }
        }
        return nil
    }

    private static func firstThumbnail(_ node: Any) -> URL? {
        if let dict = node as? [String: Any] {
            if let thumbs = dict["thumbnails"] as? [[String: Any]], let raw = thumbs.last?["url"] as? String {
                let sized = raw.replacingOccurrences(of: "=w\\d+-h\\d+[^&]*", with: "=w544-h544", options: .regularExpression)
                return URL(string: sized)
            }
            for (_, value) in dict { if let found = firstThumbnail(value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = firstThumbnail(value) { return found } }
        }
        return nil
    }

    private static func headerDict(_ json: [String: Any]) -> [String: Any]? {
        guard let header = json["header"] as? [String: Any] else { return nil }
        for (_, value) in header { if let dict = value as? [String: Any] { return dict } }
        return nil
    }

    private static func runsText(_ node: Any?) -> String {
        let runs = (dig(node, ["runs"]) as? [[String: Any]]) ?? []
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    /// Tất cả bài của một playlist YouTube / YouTube Music (đi theo trang tiếp theo, tối đa ~1000 bài).
    func playlistSongs(listId: String, completion: @escaping (Result<(name: String, songs: [Song]), Error>) -> Void) {
        let browseId = listId.hasPrefix("VL") ? listId : "VL" + listId
        music("browse", extra: ["browseId": browseId]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                var name = ""
                if let header = InnerTube.headerDict(json) { name = InnerTube.runsText(header["title"]) }
                if name.isEmpty { name = "Playlist YouTube" }
                var songs = InnerTube.parseSongs(json)
                if songs.isEmpty { completion(.failure(MochyError.badResponse("Playlist trống hoặc ở chế độ riêng tư"))); return }
                self.continuePlaylist(token: InnerTube.findToken(json), songs: songs, pages: 0) { all in
                    songs = all
                    completion(.success((name, songs)))
                }
            }
        }
    }

    private func continuePlaylist(token: String?, songs: [Song], pages: Int, done: @escaping ([Song]) -> Void) {
        guard let token = token, pages < 9 else { done(songs); return }
        music("browse", extra: ["continuation": token]) { [weak self] result in
            guard let self = self, case .success(let json) = result else { done(songs); return }
            var all = songs
            let known = Set(songs.map { $0.videoId })
            for song in InnerTube.parseSongs(json) where !known.contains(song.videoId) { all.append(song) }
            self.continuePlaylist(token: InnerTube.findToken(json), songs: all, pages: pages + 1, done: done)
        }
    }

    /// Tìm browseId nghệ sĩ theo tên (lấy liên kết nghệ sĩ có tên trùng nhất trong kết quả tìm kiếm).
    func findArtistId(name: String, completion: @escaping (String?) -> Void) {
        music("search", extra: ["query": name]) { result in
            guard case .success(let json) = result else { completion(nil); return }
            var pairs: [(String, String)] = []
            func walk(_ node: Any) {
                if let dict = node as? [String: Any] {
                    if let text = dict["text"] as? String, let id = InnerTube.artistId(in: [dict]) { pairs.append((text, id)) }
                    for (_, value) in dict { walk(value) }
                } else if let array = node as? [Any] {
                    array.forEach(walk)
                }
            }
            walk(json)
            let wanted = SongMatcher.normalize(name)
            let exact = pairs.first { SongMatcher.normalize($0.0) == wanted }
            completion((exact ?? pairs.first)?.1)
        }
    }

    func artistPage(id: String, completion: @escaping (Result<ArtistPage, Error>) -> Void) {
        music("browse", extra: ["browseId": id]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                var page = ArtistPage(name: "", thumbnail: nil, songs: [], sections: [])
                if let header = InnerTube.headerDict(json) {
                    page.name = InnerTube.runsText(header["title"])
                    page.thumbnail = InnerTube.firstThumbnail(header)
                }
                var shelves: [[String: Any]] = []
                InnerTube.collectShelves(json, into: &shelves)
                for shelf in shelves {
                    guard let contents = shelf["contents"] as? [Any] else { continue }
                    var songs: [Song] = []
                    var cards: [BrowseCard] = []
                    for element in contents {
                        guard let dict = element as? [String: Any] else { continue }
                        if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any], let song = InnerTube.makeSong(fromListItem: item) {
                            songs.append(song)
                        } else if let item = dict["musicTwoRowItemRenderer"] as? [String: Any],
                                  let browseId = InnerTube.dig(item, ["navigationEndpoint", "browseEndpoint", "browseId"]) as? String {
                            let thumbs = InnerTube.dig(item, ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail"]).flatMap { InnerTube.firstThumbnail($0) }
                            cards.append(BrowseCard(title: InnerTube.runsText(item["title"]),
                                                    subtitle: InnerTube.runsText(item["subtitle"]),
                                                    thumbnail: thumbs, browseId: browseId))
                        }
                    }
                    if page.songs.isEmpty && !songs.isEmpty {
                        let artistName = page.name
                        page.songs = songs.map { s in
                            s.artist.isEmpty
                                ? Song(videoId: s.videoId, title: s.title, artist: artistName, subtitle: s.subtitle, duration: s.duration, thumbnailURL: s.thumbnailURL)
                                : s
                        }
                    } else if !cards.isEmpty {
                        page.sections.append(ArtistSection(title: InnerTube.shelfTitle(shelf), cards: cards))
                    }
                }
                if page.name.isEmpty && page.songs.isEmpty && page.sections.isEmpty {
                    completion(.failure(MochyError.badResponse("Không đọc được trang nghệ sĩ")))
                } else {
                    completion(.success(page))
                }
            }
        }
    }

    func albumPage(id: String, completion: @escaping (Result<AlbumPage, Error>) -> Void) {
        music("browse", extra: ["browseId": id]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                var title = "", artist = ""
                var thumb: URL?
                if let header = InnerTube.headerDict(json) {
                    title = InnerTube.runsText(header["title"])
                    let sub = InnerTube.runsText(header["subtitle"]).components(separatedBy: " • ")
                    artist = sub.count > 1 ? sub[1] : (sub.first ?? "")
                    thumb = InnerTube.firstThumbnail(header)
                }
                let songs = InnerTube.parseSongs(json).map { s in
                    Song(videoId: s.videoId, title: s.title, artist: artist.isEmpty ? s.artist : artist, subtitle: title,
                         duration: s.duration, thumbnailURL: thumb ?? s.thumbnailURL)
                }
                if songs.isEmpty {
                    completion(.failure(MochyError.badResponse("Không đọc được album")))
                } else {
                    completion(.success(AlbumPage(title: title, artist: artist, thumbnail: thumb, songs: songs)))
                }
            }
        }
    }
}
