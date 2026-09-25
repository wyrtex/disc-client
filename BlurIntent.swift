import AppIntents

/// Действие для «Команд» и Action Button: переключает блюр демонстрации экрана БЕЗ открытия
/// приложения. Работает через тот же межпроцессный сигнал, что и кнопка в звонке —
/// расширение трансляции ловит его и мгновенно меняет размытие.
@available(iOS 16.0, *)
struct ToggleBlurIntent: AppIntent {
    static var title: LocalizedStringResource = "Переключить блюр стрима"
    static var description = IntentDescription("Включает или выключает размытие демонстрации экрана.")
    // Не открывать приложение — выполнить в фоне.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let current = BroadcastShared.blur
        let next = !current
        BroadcastShared.defaults?.set(next, forKey: BroadcastShared.keyBlur)
        BroadcastShared.post(next ? BroadcastShared.notifyBlurOn : BroadcastShared.notifyBlurOff)
        return .result()
    }
}

@available(iOS 16.0, *)
struct SetBlurIntent: AppIntent {
    static var title: LocalizedStringResource = "Блюр стрима"
    static var description = IntentDescription("Включить или выключить размытие демонстрации экрана.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Включить")
    var enabled: Bool

    func perform() async throws -> some IntentResult {
        BroadcastShared.defaults?.set(enabled, forKey: BroadcastShared.keyBlur)
        BroadcastShared.post(enabled ? BroadcastShared.notifyBlurOn : BroadcastShared.notifyBlurOff)
        return .result()
    }
}

/// Регистрирует действия в системе, чтобы они находились в поиске «Команд».
@available(iOS 16.0, *)
struct DiscShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleBlurIntent(),
            phrases: ["Переключить блюр в \(.applicationName)"],
            shortTitle: "Переключить блюр",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: SetBlurIntent(),
            phrases: ["Блюр в \(.applicationName)"],
            shortTitle: "Блюр стрима",
            systemImageName: "eye"
        )
    }
}
