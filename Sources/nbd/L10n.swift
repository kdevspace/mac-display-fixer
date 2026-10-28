import Foundation

/// Localization helper. `Bundle.main` is the .app bundle when running as
/// the menu bar app (→ the localized .lproj tables are used, selected by the
/// system language); when running as a bare CLI binary the tables are absent
/// and the provided fallback (Russian) is returned.
///
/// Usage: L("card.mode", "Режим")
func L(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .main, value: fallback, comment: "")
}

/// Localized format string: LF("app.virtual.hz", "%ld Гц", Int(rate))
func LF(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
    String(format: L(key, fallback), arguments: args)
}
