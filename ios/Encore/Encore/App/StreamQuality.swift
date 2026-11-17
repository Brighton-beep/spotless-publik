// Stream ios-p2: Settings › Media quality and Data Saver, wired to the core. The core has one
// streaming setting, `quality` (`HIGH` | `LOW`; `AUTO` plays as `HIGH`, it has no idea what network
// it's on). The phone does: Spotify's separate Wi-Fi and Cellular choices (and Data Saver) are kept
// as iOS settings, and this resolves them against the live network path into the core's `quality`
// whenever either one changes. A change drops the cached stream URLs and the primed next track
// (`quality_changed`), so the next song already plays at the new quality.
import Foundation
import Network

@MainActor
final class StreamQuality {
    static let shared = StreamQuality()

    /// What the radio lists offer: YouTube has two real audio tiers (about 128 kbit/s and below,
    /// and the best it has, Opus at about 160), so there is no point pretending to five.
    static let choices: [(id: String, title: String, subtitle: String)] = [
        ("auto", "Automatic", "High on Wi-Fi, Low on cellular"),
        ("low", "Low", "Saves data: up to about 128 kbit/s"),
        ("high", "High", "Best quality YouTube offers, about 160 kbit/s (Opus)"),
    ]

    private weak var app: AppModel?
    private var monitor: NWPathMonitor?
    private(set) var onCellular = false

    /// The stored choice as one of `choices` (older builds stored normal / very_high).
    static func normalized(_ v: String?, default d: String) -> String {
        switch v {
        case "auto", "low", "high": v!
        case "normal": "low"
        case "very_high": "high"
        default: d
        }
    }

    /// The core's `quality` for a network and the three settings.
    static func coreQuality(cellular: Bool, wifi: String, cell: String, dataSaver: Bool) -> String {
        if dataSaver { return "LOW" }
        switch normalized(cellular ? cell : wifi, default: "auto") {
        case "low": return "LOW"
        case "high": return "HIGH"
        default: return cellular ? "LOW" : "HIGH"
        }
    }

    func attach(_ app: AppModel) {
        self.app = app
        apply()
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let cell = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor in
                guard StreamQuality.shared.onCellular != cell else { return }
                StreamQuality.shared.onCellular = cell
                StreamQuality.shared.apply()
            }
        }
        m.start(queue: DispatchQueue(label: "spotless.stream-quality"))
        monitor = m
    }

    /// Push the resolved quality to the core if it differs from what the core has.
    func apply() {
        guard let s = app?.settings else { return }
        let want = Self.coreQuality(cellular: onCellular,
                                    wifi: s.string(SettingKey.streamQuality, default: "auto"),
                                    cell: s.string(SettingKey.cellularQuality, default: "auto"),
                                    dataSaver: s.bool(SettingKey.dataSaver))
        if s.values["quality"] != want { s.set("quality", want) }
    }
}
