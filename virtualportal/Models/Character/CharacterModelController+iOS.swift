//
//  CharacterModelController+iOS.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

#if os(iOS)
import SwiftUI
import RealityKit
import ARKit
import Combine

/// iOS-specific AR functionality for CharacterModelController
extension CharacterModelController {
    
    // MARK: - AR Session Management
    
    internal func restartARSession() {
        #if targetEnvironment(simulator)
        // ARKit capture pipeline is not available on Simulator
        print("AR session restart skipped on Simulator")
        return
        #endif
        guard let arView = arView else { return }
        
        let newConfig = createARConfiguration()
        arView.session.run(newConfig, options: [.resetTracking, .removeExistingAnchors])
        
        Task { @MainActor in
            hasPlacedModel = false
            knownPlanes.removeAll()
            lastPlaneTransform = nil
            lastPlaneExtent = nil
            lastPlaneClassification = nil
            
            if let anchor = modelAnchor {
                arView.scene.removeAnchor(anchor)
                modelAnchor = nil
            }
            modelEntity = nil
        }
        
        // AR Session restarted with new configuration
    }
    
    public func createARConfiguration() -> ARWorldTrackingConfiguration {
        #if targetEnvironment(simulator)
        // Return a default configuration; will not be run on Simulator
        return ARWorldTrackingConfiguration()
        #endif
        let configuration = ARWorldTrackingConfiguration()
        
        // Read settings from UserDefaults
        let resolution = UserDefaults.standard.string(forKey: "arResolution") ?? "1920x1080"
        _ = UserDefaults.standard.integer(forKey: "arFrameRate")  // Reserved for future use
        let objectOcclusionEnabled = UserDefaults.standard.bool(forKey: "objectOcclusionEnabled")
        
        // Configure video format based on resolution
        if let videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { format in
            let dimensions = format.imageResolution
            
            // Resolution matching
            switch resolution {
            case "3840x2160":
                return dimensions.width == 3840 && dimensions.height == 2160
            case "1920x1440":
                return dimensions.width == 1920 && dimensions.height == 1440
            case "1920x1080":
                return dimensions.width == 1920 && dimensions.height == 1080
            case "1280x720":
                return dimensions.width == 1280 && dimensions.height == 720
            default:
                return dimensions.width == 1920 && dimensions.height == 1080
            }
        }) {
            configuration.videoFormat = videoFormat
            print("AR Video Format: \(videoFormat.imageResolution.width)x\(videoFormat.imageResolution.height) @ \(videoFormat.framesPerSecond)fps")
        }
        
        // Configure frame semantics based on occlusion setting
        if objectOcclusionEnabled {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
        }
        
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        
        return configuration
    }
    
    // MARK: - Plane Detection
    
    private func planeWidthLength(_ anchor: ARPlaneAnchor) -> (Float, Float) {
        return (anchor.planeExtent.width, anchor.planeExtent.height)
    }
    
    private func planeArea(_ anchor: ARPlaneAnchor) -> Float {
        let (w, h) = planeWidthLength(anchor)
        return w * h
    }
    
    public func handlePlaneDetection(_ planeAnchor: ARPlaneAnchor, modelName: String, modelScale: Double, applyCustomShader: Bool) {
        // Early returns to prevent excessive checks
        guard !hasPlacedModel else { return }
        guard !isLoadingModel else { return } // Don't process planes while loading
        
        knownPlanes[planeAnchor.identifier] = planeAnchor
        
        // Only consider horizontal floors
        guard planeAnchor.alignment == .horizontal,
              planeAnchor.classification == .floor || planeAnchor.classification == .table else {
            return
        }
        
        let area = planeArea(planeAnchor)
        let minArea: Float = 0.2
        
        guard area >= minArea else { return }
        
        lastPlaneTransform = planeAnchor.transform
        lastPlaneExtent = SIMD2(planeAnchor.planeExtent.width, planeAnchor.planeExtent.height)
        lastPlaneClassification = planeAnchor.classification
        
        print("Found suitable plane: area=\(String(format: "%.2f", area))m², classification=\(planeAnchor.classification)")
        
        cancelFallback()
        placeModel(at: planeAnchor.transform, modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
    }
    
    public func updatePlaneAnchor(_ planeAnchor: ARPlaneAnchor, modelName: String, modelScale: Double, applyCustomShader: Bool) {
        knownPlanes[planeAnchor.identifier] = planeAnchor
        
        // Only try to place if not already placed or loading
        if !hasPlacedModel && !isLoadingModel {
            handlePlaneDetection(planeAnchor, modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
        }
    }
    
    private func placeOnBestAvailablePlane(modelName: String, modelScale: Double, applyCustomShader: Bool) -> Bool {
        let floors = knownPlanes.values.filter { $0.alignment == .horizontal && $0.classification == .floor }
        if let bestFloor = floors.max(by: { planeArea($0) < planeArea($1) }) {
            lastPlaneTransform = bestFloor.transform
            lastPlaneExtent = SIMD2(bestFloor.planeExtent.width, bestFloor.planeExtent.height)
            lastPlaneClassification = bestFloor.classification
            placeModel(at: bestFloor.transform, modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
            return true
        }
        
        let tables = knownPlanes.values.filter { $0.alignment == .horizontal && $0.classification == .table }
        if let bestTable = tables.max(by: { planeArea($0) < planeArea($1) }) {
            lastPlaneTransform = bestTable.transform
            lastPlaneExtent = SIMD2(bestTable.planeExtent.width, bestTable.planeExtent.height)
            lastPlaneClassification = bestTable.classification
            placeModel(at: bestTable.transform, modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
            return true
        }
        
        return false
    }
    
    internal func scheduleFallbackToGroundIfNeeded(modelName: String, modelScale: Double, applyCustomShader: Bool) {
        guard !hasPlacedModel else { return }
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                guard !self.hasPlacedModel else { return }
                
                if !self.placeOnBestAvailablePlane(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader) {
                    let groundTransform = simd_float4x4(
                        SIMD4(1, 0, 0, 0),
                        SIMD4(0, 1, 0, 0),
                        SIMD4(0, 0, 1, 0),
                        SIMD4(0, 0, -1, 1)
                    )
                    self.placeModel(at: groundTransform, modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
                }
            }
        }
        
        fallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }
    
    private func cancelFallback() {
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
    }
    
    // MARK: - Model Loading & Placement
    
    internal func loadAndPlaceModel(modelName: String, modelScale: Double, at transform: simd_float4x4, applyCustomShader: Bool, isLoading: @escaping @Sendable (Bool) -> Void) {
        guard let arView = arView else { return }
        guard !isLoadingModel else {
        print("Already loading a model, skipping...")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        let modelURL = modelsPath.appendingPathComponent(modelName)
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("Model file not found: \(modelURL.path)")
            return
        }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
           let fileSize = attributes[.size] as? Int64 {
            let sizeMB = Double(fileSize) / (1024 * 1024)
            print("Loading model: \(modelName) (\(String(format: "%.1f", sizeMB)) MB)")
        }
        
        isLoadingModel = true
        isLoading(true)
        
        print("Starting model load sequence...")
        let loadStartTime = CACurrentMediaTime()
        
        // Cache settings to avoid repeated UserDefaults access
        let occlusionEnabled = UserDefaults.standard.bool(forKey: "objectOcclusionEnabled")
        
        // Clear any cached data before loading to free memory
        autoreleasepool {
            self.originalMaterials = [:]
        }
        
        // Start completely off main thread to avoid any blocking
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                await MainActor.run { isLoading(false) }
                return
            }
            
            do {
                // Try to use preloaded entity, otherwise load from disk
                print("Fetching ModelEntity...")
                let fileLoadStart = CACurrentMediaTime()
                let entity = try await self.getOrLoadModelEntity(contentsOf: modelURL, modelName: modelName)
                let fileLoadDuration = CACurrentMediaTime() - fileLoadStart
                print("ModelEntity ready in \(String(format: "%.2f", fileLoadDuration))s")
                
                // Switch to MainActor for placement with yields
                await MainActor.run {
                    let placementStart = CACurrentMediaTime()
                    print("[Model Load] Starting placement...")
                    
                    Task { @MainActor in
                        // Step 1: Scale entity (fast)
                        let scaleFactor = Float(modelScale)
                        entity.scale = [scaleFactor, scaleFactor, scaleFactor]
                        
                        // Yield before next step
                        await Task.yield()
                        
                        // Step 2: Store materials
                        if let materials = entity.model?.materials {
                            self.originalMaterials[entity] = materials
                        }
                        
                        // Step 3: Remove old anchor if exists
                        if let existingAnchor = self.modelAnchor {
                            arView.scene.removeAnchor(existingAnchor)
                            self.modelAnchor = nil
                        }
                        
                        // Yield before placing
                        await Task.yield()
                        
                        // Step 4: Create and add anchor - MODEL APPEARS NOW
                        let anchor = AnchorEntity(world: transform)
                        anchor.addChild(entity)
                        arView.scene.addAnchor(anchor)
                        
                        self.modelEntity = entity
                        self.modelAnchor = anchor
                        self.hasPlacedModel = true
                        
//                        PositionController.shared.captureInitialTransform(entity)
                        
                        let placementDuration = CACurrentMediaTime() - placementStart
                        let totalDuration = CACurrentMediaTime() - loadStartTime
                        print("Placed in \(String(format: "%.2f", placementDuration))s")
                        print("Total time: \(String(format: "%.2f", totalDuration))s")
                        
                        self.isLoadingModel = false
                        isLoading(false)
                        
                        // Heavy operations AFTER model is visible
                        await Task.yield()
                        
                        // Step 5: Configure occlusion (deferred) - use cached value
                        if occlusionEnabled {
                            self.configureEntityForOcclusion(entity)
                            await Task.yield()
                        }
                        
                        // Step 6: Apply shader (slowest, most deferred)
                        if applyCustomShader {
                            print("Applying shader post-placement...")
                            await self.applyShaderToEntityAsync(entity)
                        }
                    }
                }
            } catch {
                print("Failed to load model: \(error)")
                await MainActor.run {
                    self.isLoadingModel = false
                    isLoading(false)
                }
            }
        }
    }
    
    private func configureEntityForOcclusion(_ entity: ModelEntity) {
        let occlusionEnabled = UserDefaults.standard.bool(forKey: "objectOcclusionEnabled")
        
        // Only configure if occlusion is enabled - skip unnecessary traversal
        guard occlusionEnabled else { return }
        
        // Use iterative approach with a queue for better performance
        var queue: [Entity] = [entity]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            
            if let modelEntity = current as? ModelEntity {
                modelEntity.components.set(GroundingShadowComponent(castsShadow: true))
            }
            
            queue.append(contentsOf: current.children)
        }
    }
    
    // MARK: - Model Updates
    
    public func updateModel(modelName: String, modelScale: Double, applyCustomShader: Bool) {
        guard let lastTransform = lastPlaneTransform else {
            print("No last plane transform available")
            return
        }
        
        guard let arView = arView else { return }
        
        if let existingAnchor = modelAnchor {
            arView.scene.removeAnchor(existingAnchor)
            modelAnchor = nil
            modelEntity = nil
        }
        
        hasPlacedModel = false
        loadAndPlaceModel(modelName: modelName, modelScale: modelScale, at: lastTransform, applyCustomShader: applyCustomShader) { _ in }
    }
    
    public func placeModel(at transform: simd_float4x4, modelName: String, modelScale: Double, applyCustomShader: Bool) {
        guard !modelName.isEmpty else { return }
        loadAndPlaceModel(modelName: modelName, modelScale: modelScale, at: transform, applyCustomShader: applyCustomShader) { _ in }
    }
    
    public func updateModelScale(_ scale: Double) {
        guard let entity = modelEntity else { return }
        let scaleFactor = Float(scale)
        entity.scale = [scaleFactor, scaleFactor, scaleFactor]
    }
    
    public func updateShader(_ apply: Bool) {
        guard let entity = modelEntity else { return }
        
        if apply {
            applyShaderToEntity(entity)
        } else {
            restoreOriginalMaterials(entity)
        }
    }
    
    private func restoreOriginalMaterials(_ entity: ModelEntity) {
        // Restore original materials if they were saved
        if let originalMats = originalMaterials[entity] {
            entity.model?.materials = originalMats
            originalMaterials.removeValue(forKey: entity)
        }
    }
    
    public func updateObjectOcclusion(enabled: Bool) {
        guard let arView = arView else { return }
        
        let configuration = createARConfiguration()
        arView.session.run(configuration, options: [])
        
        if let entity = modelEntity {
            configureEntityForOcclusion(entity)
        }
        
        print("Object occlusion \(enabled ? "enabled" : "disabled")")
    }
    
    public func configureARView(_ arView: ARView) {
        self.arView = arView
        #if targetEnvironment(simulator)
        print("ARKit not supported on Simulator; skipping session run.")
        return
        #endif
        let configuration = createARConfiguration()
        arView.session.run(configuration)
        initializeShaders()
    }
}
#endif
