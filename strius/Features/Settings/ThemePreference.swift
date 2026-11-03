import SwiftUI

/// 設定の「テーマ」。アプリ全体(`striusApp`)に効かせる。
nonisolated enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let storageKey: String = "settings.themePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    /// nil は端末の設定に合わせる。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
