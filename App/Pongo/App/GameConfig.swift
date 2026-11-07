import UIKit
import SpinCore

/// Branding and presentation configuration. The game title is provisional
/// and lives only here, so it can change without touching the game code.
enum GameConfig {
    static let title = "PONGO"
    static let subtitle = "3D TABLE TENNIS"
    static let fullTitle = "Pongo: 3D Table Tennis"
    static let studio = "CNMBUCK STUDIOS"

    /// Optional image asset for the Cnmbuck logo on the ball. Final brand
    /// assets have not been supplied, so when this asset is absent a neutral
    /// placeholder mark is drawn procedurally. Drop an image named
    /// `CnmbuckLogo` into Assets.xcassets to replace it.
    static let logoAssetName = "CnmbuckLogo"
    /// Optional texture for the Cnmbuck Orb surface (same rule as above).
    static let orbTextureAssetName = "CnmbuckOrb"
}

/// Cnmbuck Studios palette (midnight / charcoal / electric cyan / violet / silver).
enum Palette {
    static let midnight = UIColor(red: 0.020, green: 0.035, blue: 0.090, alpha: 1)
    static let deepBlue = UIColor(red: 0.035, green: 0.070, blue: 0.160, alpha: 1)
    static let charcoal = UIColor(red: 0.075, green: 0.080, blue: 0.095, alpha: 1)
    static let graphite = UIColor(red: 0.050, green: 0.075, blue: 0.135, alpha: 1)
    static let cyan = UIColor(red: 0.000, green: 0.880, blue: 1.000, alpha: 1)
    static let violet = UIColor(red: 0.560, green: 0.400, blue: 1.000, alpha: 1)
    static let silver = UIColor(red: 0.780, green: 0.800, blue: 0.840, alpha: 1)
    static let white = UIColor(white: 0.97, alpha: 1)
    static let textDim = UIColor(white: 0.70, alpha: 1)
}

/// Cosmetic ball skins. All skins share identical physics (the simulation
/// never sees which skin is selected).
enum BallSkin: String, Codable, CaseIterable {
    case classic, energy, orb

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .energy: return "Energy"
        case .orb: return "Cnmbuck Orb"
        }
    }
}

/// Persistent user settings.
struct AppSettings: Codable, Equatable {
    var difficulty: AIDifficulty = .intermediate
    var controls = ControlSettings()
    var soundEnabled = true
    var hapticsEnabled = true
    var showSpinIndicator = true
    var trainingOverlays = true
    var ballSkin: BallSkin = .classic

    private static let key = "pongo.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
