import SwiftUI

@main
struct DiscApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // После сворачивания iOS убивает сокет, проверяем связь при возвращении.
                    if phase == .active { store.appBecameActive() }
                }
        }
    }
}
