//
//  CharacterModelController+visionOS.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

#if os(visionOS)
import SwiftUI
import RealityKit

/// visionOS-specific functionality for CharacterModelController
extension CharacterModelController {
    
    // MARK: - visionOS Setup
    
    public func setupVisionOSAnchor(_ anchor: AnchorEntity) {
        self.modelAnchor = anchor
        print("visionOS anchor configured")
    }
    
    // MARK: - Model Loading
    
    public func loadModelForVisionOS(modelName: String, modelScale: Double, applyCustomShader: Bool) async {
        print("[visionOS] loadModelForVisionOS called with modelName: '\(modelName)' (length: \(modelName.count))")
        
        // Guard against empty or whitespace-only model names
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            print("Empty or invalid model name provided (after trimming)")
            return
        }
        
        print("[visionOS] Trimmed model name: '\(trimmedName)' (length: \(trimmedName.count))")
        
        guard !isLoadingModel else {
            print("Already loading a model, skipping...")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        print("[visionOS] Documents path: \(documentsPath.path)")
        
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        print("[visionOS] Models path: \(modelsPath.path)")
        
        // Use trimmed name for file operations
        let modelURL = modelsPath.appendingPathComponent(trimmedName)
        print("[visionOS] Model URL: \(modelURL.path)")
        
        // Verify the URL path is valid and not empty
        guard !modelURL.path.isEmpty else {
            print("Invalid model URL path (empty)")
            return
        }
        
        guard !modelURL.path.contains("\0") else {
            print("Model URL path contains null character")
            return
        }
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("Model file not found: \(modelURL.path)")
            return
        }
        
        // Verify file is readable and has size > 0
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > 0 else {
            print("Model file is invalid or empty")
            return
        }
        
        let sizeMB = Double(fileSize) / (1024 * 1024)
        print("Loading model: \(trimmedName) (\(String(format: "%.1f", sizeMB)) MB)")
        
        isLoadingModel = true
        
        // Load model off main thread to prevent UI lag
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Try to use preloaded entity, otherwise load from disk
                let entity = try await self.getOrLoadModelEntity(contentsOf: modelURL, modelName: trimmedName)
                
                // Only switch to main thread for the final scene placement
                await MainActor.run {
                    self.placeLoadedVisionOSEntity(entity, modelScale: modelScale, applyCustomShader: applyCustomShader)
                    print("visionOS model loaded successfully")
                    self.isLoadingModel = false
                }
            } catch {
                print("Failed to load visionOS model: \(error)")
                await MainActor.run {
                    self.isLoadingModel = false
                }
            }
        }
    }
    
    private func placeLoadedVisionOSEntity(_ entity: ModelEntity, modelScale: Double, applyCustomShader: Bool) {
        let scaleFactor = Float(modelScale)
        entity.scale = [scaleFactor, scaleFactor, scaleFactor]
        
        if let anchor = modelAnchor {
            if let existingEntity = modelEntity {
                existingEntity.removeFromParent()
            }
            anchor.addChild(entity)
        }
        
        modelEntity = entity
        hasPlacedModel = true
        
//        PositionController.shared.captureInitialTransform(entity)
    }
    
    // MARK: - Model Updates
    
    public func updateModelForVisionOS(modelName: String, modelScale: Double, applyCustomShader: Bool) async {
        // Guard against empty or invalid model names
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Cannot update with empty model name")
            return
        }
        
        if let existingEntity = modelEntity {
            existingEntity.removeFromParent()
            modelEntity = nil
        }
        
        hasPlacedModel = false
        await loadModelForVisionOS(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
    }
    
    public func updateObjectOcclusionForVisionOS(enabled: Bool) async {
        // visionOS handles occlusion differently through view modifiers
        print("visionOS occlusion \(enabled ? "enabled" : "disabled")")
    }
    
}
#endif
