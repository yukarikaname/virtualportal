
//
//  AboutViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/20/25.
//

import Foundation
import Combine
import SwiftUI

@MainActor
public class AboutViewModel: ObservableObject {
    // Exposed properties for AboutView
    public let appVersion: String
    public let emailURL: URL?
    public let githubURL: URL?
    public let shareURL: URL?
    public let sponsorURL: URL?
    public let mmdToUsdzTutorialURL: URL?

    public init() {
        // App version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        self.appVersion = "\(version) (\(build))"

        // Email feedback URL
        let subject = "[Virtual Portal]"
        let body = """
        App Version : \(self.appVersion)
        Category : Issue Report / Feature Request
        Expected :
        Actual :
        Reproduce :
        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        self.emailURL = URL(string: "mailto:sourceling@icloud.com?subject=\(encodedSubject)&body=\(encodedBody)")

        // GitHub & X URLs
        self.githubURL = URL(string: "https://github.com/yukarikaname/virtualportal")

        // Use GitHub as default share URL; can be overridden later
        self.shareURL = githubURL

        // Sponsor/collective
        self.sponsorURL = URL(string: "https://afdian.com/a/sourceling")
        // Tutorial: MMD -> USDZ conversion (replace with preferred tutorial)
        self.mmdToUsdzTutorialURL = URL(string: "https://www.youtube.com/watch?v=XXXXXXXXXXX")
    }
}
