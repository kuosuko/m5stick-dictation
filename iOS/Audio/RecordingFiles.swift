import AVFoundation
import Foundation
import Observation

/// The last few recordings, as sent to Whisper, kept as WAV files so a
/// dictation can be heard again when the text does not match what was said.
/// About 160 KB a pop at 16 kHz, so twenty of them stay under a few MB.
enum RecordingFiles {
    static let keep = 20

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Recordings", directoryHint: .isDirectory)
    }

    static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).wav")
    }

    static func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    static func save(_ wav: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? wav.write(to: url(for: id), options: .atomic)
    }

    /// Drops every file but the newest `keep` of `ids` (newest first).
    static func prune(keeping ids: [UUID]) {
        let wanted = Set(ids.prefix(keep).map { "\($0.uuidString).wav" })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !wanted.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Plays one recording at a time.
@MainActor
@Observable
final class Playback: NSObject, AVAudioPlayerDelegate {
    static let shared = Playback()

    private(set) var playingID: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?

    func isPlaying(_ id: UUID) -> Bool { playingID == id }

    func toggle(_ id: UUID) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: RecordingFiles.url(for: id)) else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        player.delegate = self
        self.player = player
        playingID = id
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
