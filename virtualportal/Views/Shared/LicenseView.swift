//
//  LicenseView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 8/20/25.
//

import SwiftUI

struct LicenseView: View {
    @StateObject private var viewModel = LicenseViewModel()

    var body: some View {
        List(viewModel.libraries) { lib in
            NavigationLink(destination: LicenseDetailView(library: lib)) {
                VStack(alignment: .leading) {
                    Text(lib.name)
                        .font(.headline)
                    Text(lib.licenseName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Licenses")
    }
}

struct LicenseDetailView: View {
    let library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(library.licenseName)
                    .font(.title2)
                    .bold()
                Text(library.licenseText)
                    .font(.body)
                    .multilineTextAlignment(.leading)
            }
            .padding()
        }
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    LicenseView()
}
