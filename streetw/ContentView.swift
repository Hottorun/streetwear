//
//  ContentView.swift
//  streetw
//
//  Created by Dimitris Kern on 09.08.26.
//

import SwiftData
import SwiftUI

struct ContentView: View {

    /// Dev affordance, matching `-seedBrands` / `-seedSizes`: `-startTab style`
    /// opens straight to a tab so screenshots don't need UI automation.
    @State private var selection = UserDefaults.standard.string(forKey: "startTab") ?? "feed"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Feed", systemImage: "square.stack", value: "feed") {
                FeedView()
            }
            Tab("Brands", systemImage: "tag", value: "brands") {
                BrandsView()
            }
            Tab("Saved", systemImage: "bookmark", value: "saved") {
                SavedView()
            }
            Tab("Style", systemImage: "chart.pie", value: "style") {
                StyleView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}
