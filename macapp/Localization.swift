import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case english
  case simplifiedChinese

  var id: String { rawValue }
}

enum AppLanguageStore {
  static let storageKey = "appLanguage"

  static var current: AppLanguage {
    let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.english.rawValue
    return AppLanguage(rawValue: raw) ?? .english
  }

  static func set(_ language: AppLanguage) {
    UserDefaults.standard.set(language.rawValue, forKey: storageKey)
  }

  static func text(_ english: String, _ chinese: String) -> String {
    text(english, chinese, language: current)
  }

  static func text(
    _ english: String,
    _ chinese: String,
    language: AppLanguage
  ) -> String {
    language == .simplifiedChinese ? chinese : english
  }
}
