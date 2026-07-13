import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct AppSettingsMigrationSmokeTest {
    static func main() {
        let suiteName = "com.oxi717.olc.settings-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "autoVPN")
        AppSettingsMigration.apply(defaults: defaults)
        check(defaults.bool(forKey: "autoVPN"), "upgrade should enable Auto VPN once")

        defaults.set(false, forKey: "autoVPN")
        AppSettingsMigration.apply(defaults: defaults)
        check(!defaults.bool(forKey: "autoVPN"), "migration must preserve later user choice")

        print("AppSettingsMigrationSmokeTest passed")
    }
}
