//
//  VLMModelManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/6/25.
//

#if os(iOS)
    import Foundation
    @preconcurrency import ARKit
    @preconcurrency import CoreImage
    @preconcurrency import CoreVideo
    import Combine
    import MLXLMCommon
import RealityKit

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
        @Published private var prompt: String = "Describe what you see in this scene in English."
        @Published private var promptSuffix: String =
            "Output should be brief, about 15 words or less."

        private var cancellables = Set<AnyCancellable>()
        private var currentARFrame: ARFrame?

        private init() {
            processInterval = 5.0
            downscaleResolution = true
            prompt = "Describe what you see in this scene in English."
            promptSuffix = "Output should be brief, about 15 words or less."

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
            processInterval = interval > 0 ? interval : 5.0  // Default to 5.0 instead of 2.0

            downscaleResolution = UserDefaults.standard.bool(forKey: "vlmDownscaleResolution")

            if let savedPrompt = UserDefaults.standard.string(forKey: "vlmPrompt"),
                !savedPrompt.isEmpty
            {
                prompt = savedPrompt
            }

            if let savedSuffix = UserDefaults.standard.string(forKey: "vlmPromptSuffix"),
                !savedSuffix.isEmpty
            {
                promptSuffix = savedSuffix
            }
        }

        /// Process a pre-rendered CIImage. Use this to avoid retaining ARFrame instances.
        public func processImage(_ ciImage: CIImage) async {
            guard isModelLoaded, !model.running else { return }
            await processImageInternal(ciImage)
        }

        /// Process a frame from ARSession. This runs off the main actor to avoid blocking.
        public func processFrame(_ pixelBuffer: CVPixelBuffer) async {
            guard isModelLoaded, !model.running else { return }
            // Throttle processing based on the configured interval
            let now = Date()
            if let lastTime = lastProcessedTime,
                now.timeIntervalSince(lastTime) < processInterval
            {
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

            #if os(iOS)
                if UIApplication.shared.applicationState != .active {
                    return
                }
            #endif

            let extent = ciImage.extent
            let cgImage = await Task { @MainActor in
                let context = CIContext()
                return context.createCGImage(ciImage, from: extent)
            }.value

            guard let cgImage else {
                print("Failed to render CIImage for VLM processing")
                return
            }

            let renderedImage = CIImage(cgImage: cgImage)
            await processImageInternal(renderedImage)
        }

        @MainActor
        private func processImageInternal(_ ciImage: CIImage) async {
            let userInput = UserInput(
                prompt: .text("\(prompt) \(promptSuffix)"),
                images: [.ciImage(ciImage)]
            )

            isProcessing = true
            let task = await model.generate(userInput)
            _ = await task.value
            currentOutput = model.output

            // Extract spatial information if an AR frame is available
            if let frame = currentARFrame {
                extractSpatialObjects(
                    from: model.output, frame: frame, imageSize: ciImage.extent.size)
            }

            isProcessing = false
        }

        /// Process a frame and attach a corresponding ARFrame for spatial tracking.
        public func processFrameWithSpatialTracking(_ pixelBuffer: CVPixelBuffer, arFrame: ARFrame) async {
            currentARFrame = arFrame
            await processFrame(pixelBuffer)
        }

        /// Extract objects and estimate screen/world coordinates from VLM output text.
        /// This is a heuristic parser that searches for keywords and estimates positions.
        private func extractSpatialObjects(from text: String, frame: ARFrame, imageSize: CGSize) {
            var objects: [DetectedVLMObject] = []
            let keywords = [
                "person", "chair", "table", "door", "window", "book", "phone", "cup", "bottle",
            ]

            let lowercased = text.lowercased()

            for keyword in keywords {
                if lowercased.contains(keyword) {
                    // Estimate screen position from text (defaults to center)
                    var screenX: Float = 0.5
                    var screenY: Float = 0.5
                    if lowercased.contains("left") {
                        screenX = 0.25
                    } else if lowercased.contains("right") {
                        screenX = 0.75
                    }

                    if lowercased.contains("top") {
                        screenY = 0.25
                    } else if lowercased.contains("bottom") {
                        screenY = 0.75
                    }

                    // Try to raycast from screen point to 3D world
                    let screenPoint = CGPoint(
                        x: CGFloat(screenX) * imageSize.width,
                        y: CGFloat(screenY) * imageSize.height)

                    let normalizedPoint = CGPoint(
                        x: screenPoint.x / imageSize.width,
                        y: screenPoint.y / imageSize.height)

                    // Create a raycast query; use the shared ARView's session when available
                    let query = frame.raycastQuery(
                        from: normalizedPoint,
                        allowing: .estimatedPlane,
                        alignment: .any)

                    if let session = CharacterModelController.shared.arView?.session {
                        let results = session.raycast(query)
                        if let firstResult = results.first {
                            let worldPos = firstResult.worldTransform.columns.3
                            let position = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

                            let object = DetectedVLMObject(
                                name: keyword,
                                screenPosition: SIMD2<Float>(screenX, screenY),
                                worldPosition: position,
                                confidence: 0.7
                            )
                            objects.append(object)
                        }
                    } else {
                        // Fallback: estimate 3D position from the camera transform
                        let camera = frame.camera
                        let cameraTransform = camera.transform
                        let cameraPos = SIMD3<Float>(
                            cameraTransform.columns.3.x,
                            cameraTransform.columns.3.y,
                            cameraTransform.columns.3.z)

                        // Estimate direction based on screen position
                        let angleX = (screenX - 0.5) * .pi / 3
                        let angleY = (0.5 - screenY) * .pi / 4

                        let distance: Float = 2.0
                        let estimatedPos =
                            cameraPos
                            + SIMD3<Float>(
                                sin(angleX) * distance,
                                sin(angleY) * distance,
                                -cos(angleX) * distance
                            )

                        let object = DetectedVLMObject(
                            name: keyword,
                            screenPosition: SIMD2<Float>(screenX, screenY),
                            worldPosition: estimatedPos,
                            confidence: 0.5
                        )
                        objects.append(object)
                    }
                }
            }

            detectedObjects = objects
        }

        /// Legacy method for ARSessionDelegate - converts to new method
        @available(
            *, deprecated, message: "Use processFrame(_:) instead to avoid ARFrame retention"
        )
        public func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let pixelBuffer = frame.capturedImage
            Task {
                await self.processFrame(pixelBuffer)
            }
        }

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

            // VLM cache cleared
        }
    }

    // MARK: - Supporting Types

    public struct DetectedVLMObject: Identifiable {
        public let id = UUID()
        public let name: String
        public let screenPosition: SIMD2<Float>  // Normalized (0-1, 0-1)
        public let worldPosition: SIMD3<Float>  // 3D position in world space
        public let confidence: Float  // 0.0 - 1.0
    }

#endif
