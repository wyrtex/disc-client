import SwiftUI

@main
struct DiscApp: App {
    @StateObject private var store = Store()
    @StateObject private var translator = Translator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Кэш картинок на диске: аватарки и иконки не скачиваются заново при каждом запуске.
        URLCache.shared = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(translator)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // После сворачивания iOS мог убить сокет, проверяем связь при возвращении.
                        store.appBecameActive()
                        store.voice.appDidBecomeActive()
                    case .background:
                        store.voice.appDidEnterBackground()
                    default:
                        break
                    }
                }
        }
    }
}
