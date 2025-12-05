//
//  AboutView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI

struct AboutView: View {
    @StateObject private var viewModel = AboutViewModel()

    var body: some View {
        List {
            if let sponsor = viewModel.sponsorURL {
                Link(destination: sponsor) {
                    Label("Sponsor", systemImage: "heart.fill")
                        .foregroundColor(.primary)
                }
            }

            if let github = viewModel.githubURL {
                Link(destination: github) {
                    Label("Project on GitHub", systemImage: "link")
                        .foregroundColor(.primary)
                }
            }

            if let share = viewModel.shareURL {
                ShareLink(item: share) {
                    Label("Share App", systemImage: "square.and.arrow.up")
                        .foregroundColor(.primary)
                }
            }

            if let emailURL = viewModel.emailURL {
                Link(destination: emailURL) {
                    Label("Report Issues", systemImage: "envelope")
                        .foregroundColor(.primary)
                }
            }

            NavigationLink {
                LicenseView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
                    .foregroundColor(.primary)
            }

            Section(header: Text("FAQ & Tutorials")) {
#if os(iOS)
                DisclosureGroup("Why is 60 FPS the maximum frame rate?") {
                    Text("iOS devices are limited to 60 FPS for AR camera feeds due to hardware and power constraints. Higher frame rates would cause excessive battery drain and thermal issues without significant visual improvement for AR applications.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
#endif
                DisclosureGroup("Why does my character model look weird/incorrect?") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("iOS's USDZ rendering logic has known issues:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("placeholder")
                        }
                        .font(.callout)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                
                if let tutorial = viewModel.mmdToUsdzTutorialURL {
                    Link(destination: tutorial) {
                        Label("MMD → USDZ tutorial (YouTube)", systemImage: "play.rectangle")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
