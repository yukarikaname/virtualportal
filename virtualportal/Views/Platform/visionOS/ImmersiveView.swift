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
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    handleTap(entity: value.entity)
                }
        )
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    let translation = SIMD3<Double>(value.translation3D.x, value.translation3D.y, value.translation3D.z)
                    handleDrag(entity: value.entity, translation: translation)
                }
        )
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
    
    private func handleTap(entity: Entity) {
        // Handle user interaction with the model
        let entityName = entity.name.isEmpty ? "<unnamed>" : entity.name
        print("Tapped on entity: \(entityName)")
        
        // Could trigger animations, state changes, etc.
        if entity == modelController.modelEntity {
            // Example: Trigger a response or animation
            NotificationCenter.default.post(name: .characterTapped, object: nil)
        }
    }
    
    private func handleDrag(entity: Entity, translation: SIMD3<Double>) {
        // Handle model repositioning via drag gesture
        guard let modelEntity = modelController.modelEntity,
              entity == modelEntity else { return }
        
        let translationFloat = SIMD3<Float>(
            Float(translation.x),
            Float(translation.y),
            Float(translation.z)
        )
        
        // Apply translation with scaling factor for smoother movement
        modelEntity.position += translationFloat * 0.001
    }
}
#endif
