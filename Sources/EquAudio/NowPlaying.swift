import AppKit
import Foundation

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var app: String
    var isPlaying: Bool
    var artwork: Data?
}

/// Reads the system's "now playing" item (Music, Spotify, a browser tab, any app that publishes media info).
///
/// macOS 15.4+ only answers MediaRemote queries from Apple platform binaries, so the query runs inside
/// /usr/bin/perl: perl loads Resources/NowPlayingAdapter.m (compiled to libequnp.dylib by build.sh), which asks
/// MediaRemote and prints one JSON line. This uses a private framework; if it stops working the card just reads
/// "Nothing playing" and nothing else is affected. Polled every 2 s on a background queue.
final class NowPlayingMonitor {
    var onChange: ((NowPlayingInfo?) -> Void)?
    private var timer: Timer?
    private var busy = false
    private var last: NowPlayingInfo?
    private let queue = DispatchQueue(label: "com.equaudio.nowplaying", qos: .utility)
    private let adapter = Bundle.main.url(forResource: "libequnp", withExtension: "dylib")

    private static let script = """
    use DynaLoader;
    my $l = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1;
    my $s = DynaLoader::dl_find_symbol($l, "equ_nowplaying") or exit 1;
    my $x = DynaLoader::dl_install_xsub("main::np", $s);
    &$x;
    """

    func start() {
        guard adapter != nil, timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !busy, let adapter else { return }
        busy = true
        queue.async { [weak self] in
            let info = Self.query(adapter: adapter)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if info != self.last { self.last = info; self.onChange?(info) }
            }
        }
    }

    private static func query(adapter: URL) -> NowPlayingInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, adapter.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              let title = object["title"] as? String, !title.isEmpty else { return nil }
        let rate = (object["rate"] as? NSNumber)?.doubleValue ?? 0
        return NowPlayingInfo(title: title, artist: object["artist"] as? String ?? "", album: object["album"] as? String ?? "",
                              app: object["app"] as? String ?? "", isPlaying: rate > 0,
                              artwork: (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) })
    }
}
