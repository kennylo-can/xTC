import SwiftUI
import AppKit

@main
struct xTCApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) var appLifecycle

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .defaultSize(width: 920, height: 540)
    .windowResizability(.contentSize)
    .commands {
      LanguageCommands()
    }
  }
}

final class AppLifecycle: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    AppIconSupport.apply()
  }
}

struct LanguageCommands: Commands {
  @AppStorage(AppLanguageStore.storageKey) private var languageRaw = AppLanguage.english.rawValue

  private var language: AppLanguage {
    AppLanguage(rawValue: languageRaw) ?? .english
  }

  var body: some Commands {
    CommandMenu(language == .simplifiedChinese ? "语言" : "Language") {
      Button("English") {
        languageRaw = AppLanguage.english.rawValue
      }

      Button("简体中文") {
        languageRaw = AppLanguage.simplifiedChinese.rawValue
      }
    }
  }
}
