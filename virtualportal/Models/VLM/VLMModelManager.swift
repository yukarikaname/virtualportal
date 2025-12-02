//
//  VLMModelManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/6/25.
//

import Foundation
#if canImport(ARKit)
import ARKit
#endif
import CoreImage
import CoreVideo
import Combine
import MLXLMCommon
import RealityKit
import UIKit

/// Wrapper to make CVPixelBuffer sendable across concurrency boundaries
/// This is safe because CVPixelBuffer is internally thread-safe for reading
private struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
}

/// Manages VLM processing of AR camera frames
@MainActor
public class VLMModelManager: ObservableObject {
    public static let shared = VLMModelManager()

    @Published public var currentOutput: String = ""
    @Published public var isProcessing: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var detectedObjects: [DetectedVLMObject] = []

    internal let model = FastVLMModel()
    internal private(set) var lastProcessedTime: Date?

    // MARK: - Settings
    @Published internal private(set) var processInterval: TimeInterval = 5.0
    @Published private var downscaleResolution: Bool = true
    @Published private var prompt: String = "Describe briefly in 10 words."
    @Published private var sessionPrompt: String? = nil

    private var cancellables = Set<AnyCancellable>()
#if os(iOS)
    private var currentARFrame: ARFrame?
#endif

    private init() {
        processInterval = 5.0
        downscaleResolution = true

        // Load settings asynchronously to avoid publishing during init
        Task { @MainActor in
            self.loadSettings()
        }

        // Observe settings changes
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.loadSettings()
                }
            }
            .store(in: &cancellables)

        // Load VLM model
        Task {
            await model.load()
            self.isModelLoaded = model.isModelLoaded
        }
    }

    private func loadSettings() {
        let interval = UserDefaults.standard.double(forKey: "vlmInterval")
        processInterval = interval > 0 ? interval : 5.0
        downscaleResolution = UserDefaults.standard.bool(forKey: "vlmDownscaleResolution")
    }

    /// Process a pre-rendered CIImage. Use this to avoid retaining ARFrame instances.
    public func processImage(_ ciImage: CIImage) async {
        guard isModelLoaded, !model.running else {
            #if DEBUG
            if !isModelLoaded { print("[VLM] Ignoring image: model not loaded") }
            if model.running { print("[VLM] Ignoring image: generation in progress") }
            #endif
            return
        }
        await processImageInternal(ciImage)
    }

    /// Process a frame from ARSession. This runs off the main actor to avoid blocking.
    public func processFrame(_ pixelBuffer: CVPixelBuffer) async {
        guard isModelLoaded, !model.running else {
            return
        }

        // Throttle processing based on the configured interval
        let now = Date()
        if let lastTime = lastProcessedTime, now.timeIntervalSince(lastTime) < processInterval {
            return
        }

        lastProcessedTime = now

        // Render CIImage immediately to avoid retaining the ARFrame across async boundaries.
        // Create CIImage and downscale if configured.
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if downscaleResolution {
            let scale = 480.0 / max(ciImage.extent.width, ciImage.extent.height)
            if scale < 1.0 {
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        // Render to a CGImage on the main actor to release ARFrame references
        // (avoids Metal-backed CIContext work off the main thread).
        if UIApplication.shared.applicationState != .active {
            return
        }

        let extent = ciImage.extent
        let cgImage = await MainActor.run {
            let context = CIContext()
            return context.createCGImage(ciImage, from: extent)
        }

        guard let cgImage else {
            print("Failed to render CIImage for VLM processing")
            return
        }

        let renderedImage = CIImage(cgImage: cgImage)
        await processImageInternal(renderedImage)
    }

    @MainActor
    private func processImageInternal(_ ciImage: CIImage) async {
        let effectivePrompt = sessionPrompt ?? prompt
        #if DEBUG
        print("[VLM] Begin recognition with prompt: \(effectivePrompt)")
        #endif
        let userInput = UserInput(prompt: .text(effectivePrompt), images: [.ciImage(ciImage)])

        isProcessing = true
        let start = Date()
        let task = await model.generate(userInput)
        _ = await task.value
        currentOutput = model.output
        isProcessing = false
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[VLM] Result (\(ms)ms): \(currentOutput)")
        #endif
    }

    /// Set a session-only VLM prompt that will be used until cleared. Not persisted to storage.
    public func setSessionPrompt(_ text: String?) {
        self.sessionPrompt = text
    }

    /// Set the global VLM prompt that will be persisted.
    public func setPrompt(_ text: String) {
        self.prompt = text
        // Persist to UserDefaults or something, but for now, just set.
    }

    /// Process a frame and attach a corresponding ARFrame for spatial tracking.


#if os(iOS)
    /// Legacy method for ARSessionDelegate - converts to new method
    @available(*, deprecated, message: "Use processFrame(_:) instead to avoid ARFrame retention")
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        Task {
            await self.processFrame(pixelBuffer)
        }
    }
#endif

    /// Cancel current processing
    @MainActor
    public func cancel() {
        model.cancel()
        isProcessing = false
    }

    /// Clear cached resources to free memory
    @MainActor
    public func clearCache() async {
        // Cancel any ongoing processing
        model.cancel()
        isProcessing = false

        // Clear output text
        currentOutput = ""

        // Reset last processed time to allow immediate processing when memory is available
        lastProcessedTime = nil
    }
}

// MARK: - Supporting Types

public struct DetectedVLMObject: Identifiable {
    public let id = UUID()
    public let name: String
    public let screenPosition: SIMD2<Float> // Normalized (0-1, 0-1)
    public let worldPosition: SIMD3<Float>  // 3D position in world space
    public let confidence: Float            // 0.0 - 1.0
}
