import AppKit
import Foundation

/// Lightweight update check: asks GitHub for the latest release and, if it is newer than this build, lets the
/// card show a "download" link. Nothing is downloaded or installed automatically. Only one anonymous request per
/// day goes out (to api.github.com), carrying no personal data.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?   // set only when newer than the running version
    @Published var downloadURL: URL?

    private static let api = URL(string: "https://api.github.com/repos/DaGarlic/SiliconMonitor/releases/latest")!
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func openDownload() {
        if let url = downloadURL { NSWorkspace.shared.open(url) }
    }

    private func check() {
        var req = URLRequest(url: Self.api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SiliconMonitor", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard Self.isNewer(version, than: Self.currentVersion) else { self.latestVersion = nil; return }
                    self.latestVersion = version
                    self.downloadURL = page
                }
            }
        }.resume()
    }

    /// Numeric dotted comparison: "1.10" is newer than "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
