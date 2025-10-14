//
//  CharacterModelController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

import SwiftUI
import RealityKit
#if os(iOS)
import ARKit
#endif
import Combine
import Metal

/// Centralized RealityKit-based AR scene controller
/// Platform-specific functionality is in extensions:
/// - CharacterModelController+iOS.swift
/// - CharacterModelController+visionOS.swift
/// - CharacterModelController+Shaders.swift
@MainActor
public class CharacterModelController: ObservableObject {
    public static let shared = CharacterModelController()
    
    // MARK: - Published Properties
    public internal(set) var hasPlacedModel: Bool = false
    
    // MARK: - Model State
    #if os(iOS)
    internal var arView: ARView?
    internal var lastPlaneTransform: simd_float4x4?
    internal var lastPlaneExtent: SIMD2<Float>?
    internal var lastPlaneClassification: ARPlaneAnchor.Classification?
    internal var knownPlanes: [UUID: ARPlaneAnchor] = [:]
    internal var fallbackWorkItem: DispatchWorkItem?
    #endif
    
    public var modelEntity: ModelEntity?
    internal var modelAnchor: AnchorEntity?
    internal var originalMaterials: [any RealityKit.Material]?
    
    // MARK: - Preload Cache
    private var preloadedEntity: ModelEntity?
    private var preloadedModelName: String?
    
    // MARK: - Shader Resources
    internal var metalDevice: MTLDevice?
    internal var metalLibrary: MTLLibrary?
    #if os(iOS)
    internal var celSurfaceShader: CustomMaterial.SurfaceShader?
    internal var celGeometryModifier: CustomMaterial.GeometryModifier?
    #endif
    
    // MARK: - State Flags
    internal var isLoadingModel: Bool = false
    
    // MARK: - Combine
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: .arConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartARSession()
            }
        }
        #endif
    }
    
    // MARK: - Shared Methods
    
    /// Clean up resources to prevent memory leaks
    internal func cleanup() {
        cancellables.removeAll()
        metalDevice = nil
        metalLibrary = nil
        #if os(iOS)
        celSurfaceShader = nil
        celGeometryModifier = nil
        #endif
        originalMaterials = nil
        isLoadingModel = false
    }
    
    /// Helper to load a ModelEntity
    internal func loadModelEntity(contentsOf url: URL) async throws -> ModelEntity {
        // Minimal checks - just load it
        guard !url.path.isEmpty else {
            throw NSError(domain: "CharacterModelController", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Invalid URL path"])
        }
        
        // Load directly - ModelEntity will throw if file doesn't exist
        return try await ModelEntity(contentsOf: url)
    }
    
    /// Preload a model in the background to speed up first placement
    public func preloadModel(modelName: String) async {
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("⚠️ Cannot preload empty model name")
            return
        }
        
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if already preloaded
        if preloadedModelName == trimmedName, preloadedEntity != nil {
            print("✅ Model '\(trimmedName)' already preloaded")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsPath = documentsPath.appendingPathComponent("Models", isDirectory: true)
        let modelURL = modelsPath.appendingPathComponent(trimmedName)
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("⚠️ Cannot preload - model not found: \(trimmedName)")
            return
        }
        
        print("🔄 Preloading model: \(trimmedName)...")
        
        // Load in background with low priority to not interfere with app startup
        Task.detached(priority: .utility) {
            do {
                let startTime = CACurrentMediaTime()
                // Load directly without going through self
                let entity = try await ModelEntity(contentsOf: modelURL)
                let duration = CACurrentMediaTime() - startTime
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.preloadedEntity = entity
                    self.preloadedModelName = trimmedName
                    print("✅ Model preloaded in \(String(format: "%.2f", duration))s: \(trimmedName)")
                }
            } catch {
                print("❌ Failed to preload model: \(error)")
            }
        }
    }
    
    /// Get preloaded entity if available, otherwise load normally
    internal func getOrLoadModelEntity(contentsOf url: URL, modelName: String) async throws -> ModelEntity {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if we have a preloaded entity for this model
        if let preloaded = preloadedEntity, preloadedModelName == trimmedName {
            print("⚡ Using preloaded model: \(trimmedName)")
            // Clear the cache so it's not reused
            preloadedEntity = nil
            preloadedModelName = nil
            return preloaded
        }
        
        // Not preloaded, load normally
        print("⏳ Loading model from disk: \(trimmedName)")
        return try await loadModelEntity(contentsOf: url)
    }
    
    /// Reset all state and remove model from scene
    public func reset() {
        #if os(iOS)
        if let arView = arView, let anchor = modelAnchor {
            arView.scene.removeAnchor(anchor)
        }
        #elseif os(visionOS)
        modelEntity?.removeFromParent()
        #endif
        
        modelEntity = nil
        modelAnchor = nil
        hasPlacedModel = false
        
        #if os(iOS)
        arView = nil
        lastPlaneTransform = nil
        lastPlaneExtent = nil
        lastPlaneClassification = nil
        knownPlanes.removeAll()
        isLoadingModel = false
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        celSurfaceShader = nil
        celGeometryModifier = nil
        #endif
        
        originalMaterials = nil
        metalLibrary = nil
        metalDevice = nil
        
        print("🔄 CharacterModelController reset")
    }
}
