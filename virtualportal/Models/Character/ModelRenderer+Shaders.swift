//
//  ModelRenderer+Shaders.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

// iOS support only

#if os(iOS)

import SwiftUI
import RealityKit
import Metal

/// Shader management extension for ModelRenderer
extension ModelRenderer {

    // MARK: - Shader Initialization

    internal func initializeShaders() {
        guard metalDevice == nil else {
            // If device exists, just reload shaders
            loadShaders()
            return
        }

        print("Initializing Metal shaders")

        metalDevice = MTLCreateSystemDefaultDevice()
        guard let device = metalDevice else {
            print("Failed to create Metal device")
            return
        }

        print("Metal device created: \(device.name)")

        // Try to load the default library from the main bundle
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.main) else {
            print("Metal library not available in bundle; custom shaders disabled")
            return
        }

        metalLibrary = library
        print("Metal library loaded")

        loadShaders()
    }

    private func loadShaders() {
        guard let library = metalLibrary else { return }

        #if os(iOS)
        // Load high quality surface shader
        let surfaceShader = CustomMaterial.SurfaceShader(named: "cel_surface", in: library)
        loadedShaders["cel_surface"] = surfaceShader

        // Load geometry modifier (only once)
        if !geometryModifierLoaded {
            celGeometryModifier = CustomMaterial.GeometryModifier(named: "cel_geometry_modifier", in: library)
            geometryModifierLoaded = true
        }

        celSurfaceShader = surfaceShader
        #else
        print("Custom shaders not yet supported on this platform")
        #endif
    }
    
    // MARK: - Optimized Shader Application

    internal func applyShaderToEntity(_ entity: ModelEntity) {
        #if os(iOS)
        // Save original materials before applying shader
        if originalMaterials[entity] == nil {
            originalMaterials[entity] = entity.model?.materials ?? []
        }
        
        // Ensure we have the high quality shader loaded
        if loadedShaders["cel_surface"] == nil {
            loadShaders()
        }

        guard let surfaceShader = loadedShaders["cel_surface"] ?? celSurfaceShader else {
            print("High quality surface shader not available")
            return
        }

        let entityName = entity.name.isEmpty ? "<unnamed>" : entity.name
        print("Applying high quality cel shader to entity: \(entityName)")

        // Collect all entities first to batch process
        var entitiesToProcess: [ModelEntity] = []
        collectModelEntities(from: entity, into: &entitiesToProcess)

        print("Found \(entitiesToProcess.count) entities with materials to process")

        // Process entities in optimized batches
        applyShadersToEntities(entitiesToProcess, surfaceShader: surfaceShader, async: false)

        print("Cel shader applied to \(entitiesToProcess.count) entities")
        #else
        print("Custom shaders not supported on this platform")
        #endif
    }

    /// Async version that yields between batches to keep UI responsive
    @MainActor
    internal func applyShaderToEntityAsync(_ entity: ModelEntity) async {
        #if os(iOS)
        // Ensure we have the high quality shader loaded
        if loadedShaders["cel_surface"] == nil {
            loadShaders()
        }

        guard let surfaceShader = loadedShaders["cel_surface"] ?? celSurfaceShader else {
            print("High quality surface shader not available")
            return
        }

        let entityName = entity.name.isEmpty ? "<unnamed>" : entity.name
        print("Applying high quality cel shader async to entity: \(entityName)")

        // Collect all entities
        var entitiesToProcess: [ModelEntity] = []
        collectModelEntities(from: entity, into: &entitiesToProcess)

        print("Found \(entitiesToProcess.count) entities with materials to process")

        // Process in small batches with yields to keep UI responsive
        await applyShadersToEntitiesAsync(entitiesToProcess, surfaceShader: surfaceShader)

        print("Cel shader applied async to \(entitiesToProcess.count) entities")
        #else
        print("Custom shaders not supported on this platform")
        #endif
    }

    // MARK: - Helper Methods

    private func collectModelEntities(from entity: Entity, into array: inout [ModelEntity]) {
        var queue: [Entity] = [entity]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let modelEntity = current as? ModelEntity, modelEntity.model?.materials != nil {
                array.append(modelEntity)
            }
            queue.append(contentsOf: current.children)
        }
    }

    private func applyShadersToEntities(_ entities: [ModelEntity], surfaceShader: CustomMaterial.SurfaceShader, async: Bool) {
        let batchSize = async ? 3 : 8 // Larger batches for sync processing

        for batchStart in stride(from: 0, to: entities.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entities.count)
            let batch = entities[batchStart..<batchEnd]

            for modelEntity in batch {
                applyShaderToSingleEntity(modelEntity, surfaceShader: surfaceShader)
            }
        }
    }

    private func applyShaderToSingleEntity(_ modelEntity: ModelEntity, surfaceShader: CustomMaterial.SurfaceShader) {
        guard let materials = modelEntity.model?.materials else { return }

        var shadedMaterials: [any RealityKit.Material] = []
        shadedMaterials.reserveCapacity(materials.count)

        for material in materials {
            do {
                // Try to create a CustomMaterial from existing material
                if let geomMod = celGeometryModifier {
                    let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader, geometryModifier: geomMod)
                    shadedMaterials.append(customMat)
                } else {
                    let customMat = try CustomMaterial(from: material, surfaceShader: surfaceShader)
                    shadedMaterials.append(customMat)
                }
            } catch {
                // Fail silently and use original material
                print("Failed to apply shader to material: \(error.localizedDescription)")
                shadedMaterials.append(material)
            }
        }

        modelEntity.model?.materials = shadedMaterials
    }

    private func applyShadersToEntitiesAsync(_ entities: [ModelEntity], surfaceShader: CustomMaterial.SurfaceShader) async {
        let batchSize = 3
        var processedCount = 0

        for batchStart in stride(from: 0, to: entities.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entities.count)
            let batch = entities[batchStart..<batchEnd]

            for modelEntity in batch {
                applyShaderToSingleEntity(modelEntity, surfaceShader: surfaceShader)
                processedCount += 1
            }

            // Yield after each batch to allow UI updates
            await Task.yield()
        }
    }
}

#endif
