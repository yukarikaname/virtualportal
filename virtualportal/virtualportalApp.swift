//
//  virtualportalApp.swift
//  virtualportal
//
//  Created by Yukari Kaname on 8/2/25.
//

import SwiftUI

@main
struct virtualportalApp: App {
    
    @AppStorage("firstStart") private var firstStart: Bool = false

    #if os(visionOS)
        @State private var isImmersiveSpaceShown: Bool = false
    #endif

    init() {
        // Preload model in background during app startup
        Task.detached(priority: .utility) {
            let modelName = UserDefaults.standard.string(forKey: "usdzModelName") ?? ""
            if !modelName.isEmpty {
                await CharacterModelController.shared.preloadModel(modelName: modelName)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                #if os(iOS)
                    if firstStart {
                        ModelLayerView()
                            .statusBar(hidden: true)
                    } else {
                        OnboardingView(firstStart: $firstStart)
                    }
                #elseif os(visionOS)
                    MainPageView(
                        isImmersiveSpaceShown: $isImmersiveSpaceShown, firstStart: $firstStart)
                #endif
            }
        }

        #if os(visionOS)
            ImmersiveSpace(id: "ImmersiveSpace") {
                ImmersiveView(isImmersiveSpaceShown: $isImmersiveSpaceShown)
            }
            .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #endif
    }
}
