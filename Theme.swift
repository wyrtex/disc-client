import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Theme {
    static let rail = Color(hex: 0x1E1F22)
    static let userBar = Color(hex: 0x232428)
    static let panel = Color(hex: 0x2B2D31)
    static let chat = Color(hex: 0x313338)
    static let input = Color(hex: 0x383A40)
    static let blurple = Color(hex: 0x5865F2)
    static let text = Color(hex: 0xF2F3F5)
    static let normalText = Color(hex: 0xDBDEE1)
    static let muted = Color(hex: 0x949BA4)
    static let green = Color(hex: 0x23A55A)
    static let link = Color(hex: 0x00A8FC)
}

// MARK: - Адаптация под крупные экраны (iPad)

/// На iPad (regular-ширина) ограничиваем контент телефонной шириной и центрируем на тёмном фоне,
/// чтобы интерфейс не растягивался на весь огромный экран. На iPhone — без изменений.
struct AdaptiveColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    var maxWidth: CGFloat = 760

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.rail.ignoresSafeArea())
        } else {
            content
        }
    }
}

extension View {
    /// Телефонная ширина с центрированием на iPad.
    func phoneWidth(_ maxWidth: CGFloat = 760) -> some View {
        modifier(AdaptiveColumn(maxWidth: maxWidth))
    }
}
