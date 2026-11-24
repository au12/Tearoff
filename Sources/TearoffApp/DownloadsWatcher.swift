import Foundation

/// Watches ~/Downloads and reports new PDFs once they've finished downloading.
final class DownloadsWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var seen = Set<String>()
    private let onNew: (URL) -> Void
    private let q = DispatchQueue(label: "tearoff.downloads")
    private var pendingScan = false

    init(onNew: @escaping (URL) -> Void) { self.onNew = onNew }

    var folder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    func start() {
        guard source == nil else { return }
        // remember what's already there so only new arrivals count
        seen = Set(pdfs().map { $0.path })
        fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: q)
        s.setEventHandler { [weak self] in self?.scheduleScan() }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = s
        s.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func pdfs() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { ["pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }

    private func scheduleScan() {
        guard !pendingScan else { return }
        pendingScan = true
        // browsers write a temp file and rename it; give them a moment, then wait for a stable size
        q.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.pendingScan = false
            self?.scan()
        }
    }

    private func scan() {
        for url in pdfs() where !seen.contains(url.path) {
            let age: Date? = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let a = age, Date().timeIntervalSince(a) > 300 { seen.insert(url.path); continue }
            let s1 = size(url)
            Thread.sleep(forTimeInterval: 0.4)
            let s2 = size(url)
            guard s1 > 0, s1 == s2 else { scheduleScan(); continue }
            seen.insert(url.path)
            let cb = onNew
            DispatchQueue.main.async { cb(url) }
        }
    }

    private func size(_ url: URL) -> Int {
        let v: Int? = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return v ?? 0
    }
}
