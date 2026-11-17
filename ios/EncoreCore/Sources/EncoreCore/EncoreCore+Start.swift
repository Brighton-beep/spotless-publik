import Foundation

/// Where the core keeps its files on iOS: the database, covers and player.js cache under
/// Application Support (backed up), mpv's audio cache under Caches (purgeable).
public extension CoreConfig {
    static func standard() throws -> CoreConfig {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true).appendingPathComponent("Encore")
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true).appendingPathComponent("Encore")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        return CoreConfig(dataDir: support.path, cacheDir: caches.path)
    }
}
