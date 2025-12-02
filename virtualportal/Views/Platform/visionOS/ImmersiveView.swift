//
//  ImmersiveView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 8/2/25.
//

#if os(visionOS)
import SwiftUI
import RealityKit
import ARKit
import AVFoundation

struct ImmersiveView: View {
    // MARK: - ViewModels
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var arViewModel = ARViewModel()
    @StateObject private var modelController = CharacterModelController.shared
    
    @Binding var isImmersiveSpaceShown: Bool
    
    // Track the anchor entity
    @State private var rootAnchor: AnchorEntity?

    var body: some View {
        RealityView { content in
            // Setup the RealityKit content with world anchor
            let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: [0.3, 0.3]))
            content.add(anchor)
            rootAnchor = anchor
            
            // Setup controller with this anchor
            Task { @MainActor in
                await setupImmersiveSpace(anchor: anchor)
            }
        } update: { content in
            // Handle updates to model properties
            Task { @MainActor in
                await updateModel()
            }
        }
        .upperLimbVisibility(settingsViewModel.objectOcclusionEnabled ? .automatic : .hidden)
        .persistentSystemOverlays(settingsViewModel.objectOcclusionEnabled ? .automatic : .hidden)
        .onAppear {
            // visionOS handles immersive space lifecycle differently
            print("ImmersiveView appeared")
            isImmersiveSpaceShown = true
            Task {
                // Guard against empty model names to prevent nullptr crashes
                let modelName = settingsViewModel.usdzModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !modelName.isEmpty {
                    print("Loading model: \(modelName)") 
                    await modelController.loadModelForVisionOS(
                        modelName: modelName,
                        modelScale: settingsViewModel.modelScale,
                        applyCustomShader: settingsViewModel.applyCustomShader
                    )
                } else {
                    print("No model name specified - skipping model load")
                }
            }
        }
        .onDisappear {
            // Clean up resources properly
            print("ImmersiveView disappeared")
            isImmersiveSpaceShown = false
            Task { @MainActor in
                modelController.reset()
            }
        }
    }
    
    private func setupImmersiveSpace(anchor: AnchorEntity) async {
        // Configure the immersive space for visionOS
        modelController.setupVisionOSAnchor(anchor)
        
        // Configure occlusion settings
        await modelController.updateObjectOcclusionForVisionOS(enabled: settingsViewModel.objectOcclusionEnabled)
        
        // Load the model if specified - guard against empty strings
        let modelName = settingsViewModel.usdzModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelName.isEmpty {
            await modelController.loadModelForVisionOS(
                modelName: modelName,
                modelScale: settingsViewModel.modelScale,
                applyCustomShader: settingsViewModel.applyCustomShader
            )
        } else {
            print("No valid model name in setupImmersiveSpace")
        }
    }
    
    private func updateModel() async {
        // Guard against empty model names
        let modelName = settingsViewModel.usdzModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            print("Cannot update with empty model name")
            return
        }
        
        // Update model when properties change
        await modelController.updateModelForVisionOS(
            modelName: modelName,
            modelScale: settingsViewModel.modelScale,
            applyCustomShader: settingsViewModel.applyCustomShader
        )
        
        // Update occlusion settings
        await modelController.updateObjectOcclusionForVisionOS(enabled: settingsViewModel.objectOcclusionEnabled)
    }
}
#endif
