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
                .onAppear {
                    // Перевод субтитров голоса идёт через общую очередь переводчика.
                    store.voice.translateCaption = { [translator] text, from, to in
                        await translator.translateCaption(text, from: from, to: to)
                    }
                }
                .onOpenURL { url in
                    // Управление блюром из приложения «Команды»:
                    // discclient://blur/on | off | toggle
                    guard url.scheme == "discclient", url.host == "blur" else { return }
                    let action = url.pathComponents.last ?? "toggle"
                    switch action {
                    case "on": store.voice.setBlur(true)
                    case "off": store.voice.setBlur(false)
                    default: store.voice.toggleBlur()
                    }
                }
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
