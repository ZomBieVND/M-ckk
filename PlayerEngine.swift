import Foundation
import AVFoundation
import MediaPlayer
import UIKit

extension Notification.Name {
    static let playerStateChanged = Notification.Name("MochyiOSPlayerStateChanged")
    static let playerTimeChanged = Notification.Name("MochyiOSPlayerTimeChanged")
    static let playerFailed = Notification.Name("MochyiOSPlayerFailed")
}

enum RepeatMode: Int {
    case off = 0
    case all = 1
    case one = 2
}

/// Bộ phát nhạc: hàng đợi, ngẫu nhiên, lặp, hẹn giờ tắt, AVPlayer, phát nền, điều khiển ở màn hình khoá.
final class PlayerEngine: NSObject {
    static let shared = PlayerEngine()

    private(set) var queue: [Song] = []
    private(set) var index: Int = -1
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var artwork: UIImage?
    private(set) var lastError: String?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleOn = false
    private(set) var streamInfo: StreamInfo?
    private(set) var isLocal = false
    private(set) var sleepEnd: Date?

    var currentSong: Song? {
        if index >= 0 && index < queue.count { return queue[index] }
        return nil
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var requestToken = 0
    private var resumeAfterInterruption = false
    private var sleepTimer: Timer?
    private var watchdog: Timer?
    private var failObserver: NSObjectProtocol?
    private var stallSeconds = 0
    private var lastWatchTime: Double = -1
    private var recoveries = 0
    private var pendingSeek: Double = 0

    private override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
    }

    // MARK: - Điều khiển

    private(set) var contextTitle: String?

    func play(queue: [Song], index: Int, context: String? = nil) {
        guard index >= 0 && index < queue.count else { return }
        contextTitle = context
        var list = queue
        var start = index
        if shuffleOn {
            let first = list.remove(at: index)
            list.shuffle()
            list.insert(first, at: 0)
            start = 0
        }
        self.queue = list
        self.index = start
        startCurrent()
    }

    /// Phát ngẫu nhiên cả danh sách.
    func playShuffled(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        shuffleOn = true
        play(queue: songs, index: Int(arc4random_uniform(UInt32(songs.count))))
    }

    func setShuffle(_ on: Bool) {
        shuffleOn = on
        if on && index >= 0 && index < queue.count {
            var rest = Array(queue[(index + 1)...])
            rest.shuffle()
            queue = Array(queue[0...index]) + rest
        }
        postState()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        postState()
    }

    func playNext(_ song: Song) {
        if queue.isEmpty || index < 0 {
            play(queue: [song], index: 0)
            return
        }
        queue.insert(song, at: index + 1)
        postState()
    }

    func addToQueue(_ song: Song) {
        if queue.isEmpty || index < 0 {
            play(queue: [song], index: 0)
            return
        }
        queue.append(song)
        postState()
    }

    func jump(to newIndex: Int) {
        guard newIndex >= 0 && newIndex < queue.count else { return }
        index = newIndex
        startCurrent()
    }

    func removeFromQueue(at position: Int) {
        guard position >= 0 && position < queue.count else { return }
        queue.remove(at: position)
        if queue.isEmpty {
            clear()
        } else if position < index {
            index -= 1
            postState()
        } else if position == index {
            if index >= queue.count { index = queue.count - 1 }
            startCurrent()
        } else {
            postState()
        }
    }

    func moveInQueue(from: Int, to: Int) {
        guard from >= 0, to >= 0, from < queue.count, to < queue.count, from != to else { return }
        let song = queue.remove(at: from)
        queue.insert(song, at: to)
        if index == from {
            index = to
        } else if from < index && to >= index {
            index -= 1
        } else if from > index && to <= index {
            index += 1
        }
        postState()
    }

    func clear() {
        requestToken += 1
        teardownPlayer()
        queue = []
        index = -1
        isPlaying = false
        isLoading = false
        duration = 0
        currentTime = 0
        artwork = nil
        streamInfo = nil
        postState()
        updateNowPlayingInfo()
    }

    /// Hẹn giờ tắt nhạc; nil hoặc 0 để huỷ.
    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepEnd = nil
        if let m = minutes, m > 0 {
            let seconds = Double(m) * 60.0
            sleepEnd = Date().addingTimeInterval(seconds)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                self?.sleepEnd = nil
                self?.sleepTimer = nil
                self?.pause()
            }
        }
        postState()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let player = player, !isLoading else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        postState()
        updateNowPlayingInfo()
    }

    func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        postState()
        updateNowPlayingInfo()
    }

    func next() {
        advance()
    }

    private func advance() {
        if index + 1 < queue.count {
            index += 1
            startCurrent()
        } else if repeatMode == .all && !queue.isEmpty {
            index = 0
            startCurrent()
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if currentTime > 3 || index <= 0 {
            seek(to: 0)
        } else {
            index -= 1
            startCurrent()
        }
    }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentTime = max(0, seconds)
                self?.updateNowPlayingInfo()
                NotificationCenter.default.post(name: .playerTimeChanged, object: nil)
            }
        }
    }

    // MARK: - Nội bộ

    private func startCurrent() {
        guard let song = currentSong else { return }
        requestToken += 1
        let token = requestToken
        teardownPlayer()
        recoveries = 0
        forceChunk = false
        pendingSeek = 0
        isLoading = true
        isPlaying = false
        duration = 0
        currentTime = 0
        artwork = nil
        lastError = nil
        postState()
        updateNowPlayingInfo()
        loadArtwork(for: song, token: token)
        streamInfo = nil

        if let local = Library.shared.localURL(for: song.videoId) {
            isLocal = true
            localRealDuration = DownloadStore.realDuration(for: song)
            begin(url: local, headers: nil)
            return
        }
        isLocal = false
        InnerTube.shared.resolveStream(videoId: song.videoId) { [weak self] result in
            guard let self = self, token == self.requestToken else { return }
            switch result {
            case .success(let info):
                self.streamInfo = info
                self.begin(url: info.url, headers: ["User-Agent": info.userAgent], stream: (info.unverified || self.forceChunk) ? info : nil)
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private var chunkLoader: ChunkedLoader?
    private var forceChunk = false   // lần đầu lỗi khi phát trực tuyến: các lần thử lại dùng ChunkedLoader

    /// Vị trí phát chính xác (cập nhật từng khung hình), dùng cho lời chạy từng từ.
    var livePosition: Double {
        guard let p = player else { return currentTime }
        let t = p.currentTime().seconds
        return t.isFinite ? t : currentTime
    }
    private var durationCapped = false
    private var localRealDuration: Double = 0   // độ dài thật của bài đã tải

    private func begin(url: URL, headers: [String: String]?, stream: StreamInfo? = nil) {
        try? AVAudioSession.sharedInstance().setActive(true)
        var options: [String: Any]? = nil
        if let headers = headers {
            options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        }
        let asset: AVURLAsset
        if let stream = stream, let loader = ChunkedLoader(stream: stream) {
            chunkLoader = loader
            asset = AVURLAsset(url: loader.assetURL, options: nil)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        } else {
            chunkLoader = nil
            asset = AVURLAsset(url: url, options: options)
        }
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.itemStatusChanged(observedItem)
            }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: DispatchQueue.main
        ) { [weak self] time in
            self?.tick(time)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: OperationQueue.main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.repeatMode == .one {
                self.seek(to: 0)
                self.player?.play()
            } else {
                self.advance()
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: OperationQueue.main
        ) { [weak self] note in
            guard let self = self else { return }
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                ?? MochyError.playback("Luồng nhạc bị ngắt giữa chừng")
            if !self.recover() { self.fail(error) }
        }
        startWatchdog()
        newPlayer.play()
    }

    /// Phát lại từ vị trí hiện tại bằng link mới khi luồng bị đứt / hết hạn / kẹt. Trả về false nếu đã thử quá 3 lần.
    @discardableResult
    private func recover() -> Bool {
        guard let song = currentSong, recoveries < 3 else { return false }
        recoveries += 1
        let resumeAt = currentTime
        requestToken += 1
        let token = requestToken
        teardownPlayer()
        isLoading = true
        isPlaying = false
        postState()
        if let local = Library.shared.localURL(for: song.videoId) {
            pendingSeek = resumeAt
            begin(url: local, headers: nil)
            return true
        }
        InnerTube.shared.resolveStream(videoId: song.videoId) { [weak self] result in
            guard let self = self, token == self.requestToken else { return }
            switch result {
            case .success(let info):
                self.streamInfo = info
                self.pendingSeek = resumeAt
                self.begin(url: info.url, headers: ["User-Agent": info.userAgent], stream: (info.unverified || self.forceChunk) ? info : nil)
            case .failure(let error):
                self.fail(error)
            }
        }
        return true
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        stallSeconds = 0
        lastWatchTime = -1
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchTick()
        }
    }

    /// Mỗi giây kiểm tra: nếu đang "phát" mà thời gian không chạy thì đẩy nhẹ, kẹt lâu thì lấy link mới.
    private func watchTick() {
        guard let p = player, !isLoading, isPlaying else {
            stallSeconds = 0
            return
        }
        let now = p.currentTime().seconds
        let advanced = lastWatchTime < 0 || now > lastWatchTime + 0.2
        lastWatchTime = now
        if p.timeControlStatus == .playing && advanced {
            stallSeconds = 0
            return
        }
        if p.timeControlStatus == .paused {
            // Hệ thống tạm dừng ngoài ý muốn: đồng bộ lại giao diện, không tự phát lại.
            isPlaying = false
            postState()
            updateNowPlayingInfo()
            return
        }
        stallSeconds += 1
        if stallSeconds == 4 {
            p.play()
        } else if stallSeconds >= 12 {
            stallSeconds = 0
            if !recover() {
                fail(MochyError.playback("Mạng bị đứt, nhạc dừng giữa chừng. Hãy thử phát lại."))
            }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = item.duration.seconds
            duration = seconds.isFinite ? seconds : 0
            // Tệp DASH của YouTube đôi khi khai độ dài sai (bài 3:54 hiện 6:50): tin độ dài YouTube trả về.
            let real = isLocal ? localRealDuration : (streamInfo?.durationSeconds ?? 0)
            if real > 0 && (duration <= 0 || abs(duration - real) > 2) {
                duration = real
                durationCapped = true
            } else {
                durationCapped = false
            }
            isLoading = false
            isPlaying = true
            if pendingSeek > 1 {
                let target = pendingSeek
                pendingSeek = 0
                player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                currentTime = target
            }
            if recoveries == 0, let song = currentSong { Library.shared.addHistory(song); PlayLog.shared.record(song) }
            postState()
            updateNowPlayingInfo()
        case .failed:
            let error: Error = item.error ?? MochyError.playback("AVPlayer báo lỗi không rõ")
            if !isLocal && chunkLoader == nil { forceChunk = true }
            if !recover() { fail(error) }
        default:
            break
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = seconds }
        if durationCapped, duration > 0, seconds.isFinite, seconds >= duration - 0.3, isPlaying {
            durationCapped = false
            player?.pause()
            if repeatMode == .one {
                seek(to: 0)
                player?.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.durationCapped = true }
            } else {
                advance()
            }
            return
        }
        NotificationCenter.default.post(name: .playerTimeChanged, object: nil)
    }

    private func fail(_ error: Error) {
        teardownPlayer()
        isLoading = false
        isPlaying = false
        let message = describe(error)
        lastError = message
        postState()
        updateNowPlayingInfo()
        NotificationCenter.default.post(name: .playerFailed, object: nil, userInfo: ["message": message])
    }

    private func describe(_ error: Error) -> String {
        if let mochy = error as? MochyError {
            return mochy.errorDescription ?? "Lỗi không rõ"
        }
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "\n↳ \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    private func teardownPlayer() {
        chunkLoader = nil
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
            endObserver = nil
        }
        if let failed = failObserver {
            NotificationCenter.default.removeObserver(failed)
            failObserver = nil
        }
        watchdog?.invalidate()
        watchdog = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
    }

    private func loadArtwork(for song: Song, token: Int) {
        guard let url = song.largeThumbnailURL else { return }
        ImageLoader.shared.load(url) { [weak self] image in
            guard let self = self, token == self.requestToken, let image = image else { return }
            self.artwork = image
            self.postState()
            self.updateNowPlayingInfo()
        }
    }

    private func postState() {
        NotificationCenter.default.post(name: .playerStateChanged, object: nil)
    }

    // MARK: - Hệ thống

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: positionEvent.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        } else {
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if resumeAfterInterruption && options.contains(.shouldResume) {
                resume()
            }
            resumeAfterInterruption = false
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable && isPlaying {
            DispatchQueue.main.async { [weak self] in
                self?.pause()
            }
        }
    }
}
