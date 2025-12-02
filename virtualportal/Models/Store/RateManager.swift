//
//  RateManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/20/25.
//

import Foundation
import StoreKit
import SwiftUI

@MainActor
public class RateManager {
    public static let shared = RateManager()

    private let launchesKey = "app_launch_count"
    private let didAskKey = "app_rate_asked"
    private let thresholdKey = "app_rate_threshold"

    // Default threshold - ask after this many launches
    public var threshold: Int {
        let t = UserDefaults.standard.integer(forKey: thresholdKey)
        return t > 0 ? t : 5
    }

    private init() {}

    // Centralized helper to request in-app reviews using the best available API.
    private func requestReview(in windowScene: UIWindowScene?) {
        
        guard let scene = windowScene else {
            print("RequestReview aborted: No valid UIWindowScene provided.")
            return
        }
        
        AppStore.requestReview(in: scene)
    }

    /// Register an app launch. When threshold reached and not asked before, post notification.
    public func registerLaunch() {
        var count = UserDefaults.standard.integer(forKey: launchesKey)
        count += 1
        UserDefaults.standard.set(count, forKey: launchesKey)

        let didAsk = UserDefaults.standard.bool(forKey: didAskKey)
        if !didAsk && count >= threshold {
            Task { @MainActor in
                let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene

                guard let scene = windowScene else {
                    print("RequestReview aborted: No valid UIWindowScene provided.")
                    return
                }
                
                AppStore.requestReview(in: scene)
                markAsked()
                return

            }
        }
    }

    /// Mark that we've shown the rate prompt (and should not show again)
    public func markAsked() {
        UserDefaults.standard.set(true, forKey: didAskKey)
    }

    /// Reset counters (for testing)
    public func reset() {
        UserDefaults.standard.removeObject(forKey: launchesKey)
        UserDefaults.standard.removeObject(forKey: didAskKey)
    }
}
