import Foundation

enum AppSettingsMigration {
    private static let autoVPNMigrationKey = "settingsMigration.autoVPNDefault.v1"

    static func apply(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: autoVPNMigrationKey) == nil else { return }
        defaults.set(true, forKey: "autoVPN")
        defaults.set(true, forKey: autoVPNMigrationKey)
    }
}
