import SwiftUI

struct SettingsDescriptionRow<Content: View>: View {
    let title: String
    let description: String
    var badgeText: String? = nil
    var helperText: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.brandYellow)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }

            Text(description)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let helperText {
                Text(helperText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brandBlue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
    }
}
