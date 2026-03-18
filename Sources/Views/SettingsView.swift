import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .api

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsAPITabView()
                .tabItem {
                    Label("API", systemImage: "key.fill")
                }
                .tag(SettingsTab.api)

            SettingsUTOAlignTabView()
                .tabItem {
                    Label("UTO-ALIGN", systemImage: "slider.horizontal.3")
                }
                .tag(SettingsTab.utoAlign)
        }
    }
}
