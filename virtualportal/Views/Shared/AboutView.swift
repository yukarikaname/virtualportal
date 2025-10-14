//
//  AboutView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI

struct AboutView: View {
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
    
    private var emailURL: URL? {
        let subject = "[Virtual Portal]"
        let body = """
        App Version : \(appVersion)
        Category : Issue Report / Feature Request
        Expected :
        Actual :
        Reproduce :
        """
        
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        return URL(string: "mailto:sourceling@icloud.com?subject=\(encodedSubject)&body=\(encodedBody)")
    }

    var body: some View {
        List {
            Link(destination: URL(string: "https://opencollective.com/virtualportal")!) {
                Label("Sponsor", systemImage: "heart.fill")
                    .foregroundColor(.primary)
            }
            
            if let emailURL = emailURL {
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
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
