import SwiftUI

extension Color {
    static let backgroundYellow = Color(red: 1.0, green: 0.97, blue: 0.84)
    static let brandViolet = Color(red: 0.47, green: 0.33, blue: 0.95)
    static let brandPink = Color(red: 0.95, green: 0.28, blue: 0.60)
    static let brandBlue = Color(red: 0.23, green: 0.53, blue: 0.96)
    static let brandGreen = Color(red: 0.45, green: 0.87, blue: 0.39)
    static let brandYellow = Color(red: 0.98, green: 0.86, blue: 0.30)
    static let webHighlightYellow = Color(red: 0.99, green: 0.93, blue: 0.63)
    static let webHighlightChip = Color(red: 0.97, green: 0.88, blue: 0.42)
    static let brandPurple = Color(red: 0.76, green: 0.68, blue: 1.00)
    static let brandOrange = Color(red: 0.98, green: 0.68, blue: 0.37)
    static let brandCyan = Color(red: 0.53, green: 0.93, blue: 0.95)
}

struct StudioPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black)
                    .offset(x: 5, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.black, lineWidth: 2)
            )
    }
}

extension View {
    func studioPanelChrome() -> some View {
        modifier(StudioPanelChrome())
    }

    func studioOffsetShadow(cornerRadius: CGFloat, x: CGFloat, y: CGFloat, enabled: Bool = true) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.black)
                .offset(x: x, y: y)
                .opacity(enabled ? 1 : 0)
        )
    }
}
