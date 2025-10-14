//
//  ConversationManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine
import AVFoundation

public final class ConversationManager: ObservableObject {
    public static let shared = ConversationManager()
    
    private let speech = SpeechRecognitionManager.shared
    private let tts = TextToSpeechManager.shared
    private let positionController = PositionController.shared
    private let memoryManager = MemoryManager.shared
    private let lipSync = LipSyncController.shared
    private let trainer = OnDeviceMLTrainer.shared
    #if os(iOS)
    private let vlm = VLMModelManager.shared
    #endif
    
    private let llm = FoundationLLM()
    
    @Published public private(set) var lastUserSentence: String = ""
    @Published public private(set) var lastVLMSummary: String = ""
    @Published public private(set) var lastLLMResponse: String = ""
    @Published public private(set) var isGenerating: Bool = false
    
    private var currentLLMTask: Task<Void, Never>? = nil
    private var cancellables = Set<AnyCancellable>()
    private var conversationTurnCount: Int = 0
    private var isPaused: Bool = false
    
    private init() {
        #if os(iOS)
        VLMModelManager.shared.$currentOutput
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .utility))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.lastVLMSummary = text
            }
            .store(in: &cancellables)
        #endif
    }
    
    public func start() {
        
        // Check permissions status
        let permissions = speech.checkPermissions()
        
        // Check if speech recognition is authorized
        if !speech.isAuthorized {
            print("Speech recognition not authorized. Please grant permissions.")
        }
        
        // Start continuous speech recognition
        speech.onSentenceRecognized = { [weak self] sentence in
            // Handle on background thread to avoid blocking UI
            Task.detached { [weak self] in
                await self?.handleUserSentence(sentence)
            }
        }
        
        // Start speech recognition asynchronously
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let isAuthorized = await MainActor.run { self.speech.isAuthorized }
            guard isAuthorized else {
                print("Speech recognition not authorized yet")
                return
            }
            
            print("Starting speech recognition after AR initialization")
            
            // Start speech recognition - the manager dispatches internally
            await MainActor.run {
                self.speech.start()
            }
            
            print("ConversationManager started - listening for speech")
        }
    }
    
    
    private func handleUserSentence(_ sentence: String) async {
    print("User: \(sentence)")
        
    // Do heavy work off main thread
        let vlmContext = await MainActor.run { lastVLMSummary }
        
        if !vlmContext.isEmpty {
            print("VLM context: \(vlmContext)")
        }
        
        let prompt = buildPrompt(user: sentence, vision: vlmContext)
        
        // Update UI state on main thread
        await MainActor.run {
            currentLLMTask?.cancel()
            isGenerating = true
            lastUserSentence = sentence
            lastLLMResponse = ""
            tts.stop()
            lipSync.stopLipSync() // Stop any ongoing lip sync
        }
        await MainActor.run {
            currentLLMTask?.cancel()
            isGenerating = true
            lastUserSentence = sentence
            lastLLMResponse = ""
            tts.stop()
        }
        
        print("Generating LLM response...")
        
        // Create task for LLM streaming
        let task = Task { [weak self] in
            guard let self else {
                print("[ConversationManager] Self is nil in LLM task")
                return
            }
            
            // Stream response without blocking main thread
            await self.llm.streamResponse(prompt) { [weak self] (chunk: String, finished: Bool) in
                guard let self else { return }
                
                // Update UI and process commands
                Task { @MainActor in
                    if !chunk.isEmpty {
                        self.lastLLMResponse += (self.lastLLMResponse.isEmpty ? "" : " ") + chunk
                        // Only log first and last chunks to reduce console spam
                        if self.lastLLMResponse.count < 50 || finished {
                            print("LLM: \(chunk)")
                        }
                        
                    // Parse and execute commands from the chunk
                    let commands = self.positionController.parseCommands(from: chunk)
                    for command in commands {
                        Task {
                            await self.positionController.execute(command)
                        }
                    }
                    
                    // Parse and execute memory commands
                    self.memoryManager.executeMemoryCommand(chunk)
                }
                
                // Speak each chunk as it arrives (already punctuation-delimited)
                // Remove command syntax from speech
                if !chunk.isEmpty {
                    let cleanChunk = chunk
                        .replacingOccurrences(of: #"\[COMMAND:.*?\]"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\[MEMORY:.*?\]"#, with: "", options: .regularExpression)
                    
                    if !cleanChunk.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Start lip sync when speaking begins
                        self.lipSync.startLipSync()
                        self.tts.speak(cleanChunk, streaming: false)
                    }
                }
                if finished {
                        self.isGenerating = false
                        self.conversationTurnCount += 1
                        
                        // Stop lip sync when done speaking (add small delay to let TTS finish)
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                            await MainActor.run {
                                self.lipSync.stopLipSync()
                            }
                        }
                        
                        // Note: Memory extraction now handled by LLM via [MEMORY:save,...] commands
                        // No automatic extraction needed
                        
                        // Collect training data for on-device learning
                        self.collectTrainingData(
                            userInput: sentence,
                            llmResponse: self.lastLLMResponse,
                            hadCommands: !self.positionController.parseCommands(from: self.lastLLMResponse).isEmpty
                        )
                        
                        print("LLM response complete")
                    }
                }
            }
        }
        
        // Store task on main actor
        await MainActor.run {
            currentLLMTask = task
        }
    }
    
    private func buildPrompt(user: String, vision: String) -> String {
        var lines: [String] = []
        
        // Get character description from settings
        let characterDesc = UserDefaults.standard.string(forKey: "promptText") ?? "A friendly AR character"
        
        lines.append("# CHARACTER IDENTITY")
        lines.append("You ARE the AR character. You exist in the user's physical space.")
        lines.append("Your appearance: \(characterDesc)")
        lines.append("")
        
        // Add memory context if available
        let memoryContext = memoryManager.generateMemoryContext()
        if !memoryContext.isEmpty {
            lines.append("# YOUR MEMORIES")
            lines.append(memoryContext)
            lines.append("")
        }
        
        // Add memory function calling documentation
        lines.append(MemoryManager.getFunctionCallingPrompt())
        lines.append("")
        
        // Add visual context
        if !vision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("# WHAT YOU SEE")
            lines.append("Through your vision system, you observe: \(vision)")
            lines.append("")
        }
        
        lines.append("# CONVERSATION")
        lines.append("User says: \(user)")
        lines.append("")
        
        lines.append("# YOUR CAPABILITIES")
        lines.append("As a physical AR entity, you can:")
        lines.append("- SEE the real environment through your vision system")
        lines.append("- MOVE yourself in 3D space")
        lines.append("- EXPRESS emotions through poses and facial expressions")
        lines.append("- REMEMBER past conversations and user preferences")
        lines.append("- CONVERSE naturally - commands are OPTIONAL, not required")
        lines.append("")
        
        lines.append("# RESPONSE GUIDELINES")
        lines.append("1. Respond as YOURSELF, the character - use 'I', 'me', 'my'")
        lines.append("2. React to what you SEE in the environment")
        lines.append("3. Be conversational and natural - no need for commands in every response")
        lines.append("4. Commands are for MOVEMENT and EXPRESSION when contextually appropriate")
        lines.append("5. Keep responses concise (1-3 sentences unless asked for more)")
        lines.append("")
        
        lines.append("# OPTIONAL COMMANDS (use when contextually appropriate)")
        lines.append("You can embed commands to move and express yourself:")
        lines.append("")
        lines.append("MOVEMENT:")
        lines.append("- [COMMAND:moveto,fromX,fromY,fromZ,toX,toY,toZ,duration] - smooth movement")
        lines.append("- [COMMAND:move,x,y,z] - instant position")
        lines.append("- [COMMAND:moverel,x,y,z] - move relative to current position")
        lines.append("- [COMMAND:lookat,x,y,z] - turn toward a point")
        lines.append("")
        lines.append("EXPRESSIONS:")
        lines.append("- [COMMAND:pose,wave,2.0] - wave gesture")
        lines.append("- [COMMAND:pose,happy,2.0] - happy expression")
        lines.append("- [COMMAND:pose,surprised,1.5] - surprised look")
        lines.append("- [COMMAND:pose,think,2.0] - thinking pose")
        lines.append("- [COMMAND:pose,sad,2.0] - sad expression")
        lines.append("- [COMMAND:pose,point,1.5] - pointing gesture")
        lines.append("")
        lines.append("EXAMPLES:")
        lines.append("✓ 'That's interesting!' - pure conversation, no command needed")
        lines.append("✓ 'Let me get closer. [COMMAND:moveto,0,0,0,0.5,0,0,1.5]' - movement when relevant")
        lines.append("✓ 'I'm so happy to see you! [COMMAND:pose,wave,2.0]' - expression when greeting")
        lines.append("✓ 'I see a beautiful sunset in front of you.' - commenting on vision")
        lines.append("")
        lines.append("Remember: Commands are hidden from speech. Only your words are spoken with automatic lip sync.")
        lines.append("")
        lines.append("Respond now as yourself:")
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Training Data Collection
    
    private func collectTrainingData(userInput: String, llmResponse: String, hadCommands: Bool) {
        // Estimate user sentiment (simple keyword analysis)
        let userSentiment = estimateSentiment(text: userInput)
        
        // Get character position if available
        let characterPos = positionController.currentPosition
        
        // Estimate distance to user (placeholder - in real implementation, use ARKit)
        let distanceToUser: Float = 1.5
        
        // Get environment brightness (placeholder - in real implementation, use camera)
        let environmentBrightness: Float = 0.7
        
        // Build context
        let context = BehaviorContext(
            timeOfDay: getCurrentTimeOfDay(),
            userSentiment: Double(userSentiment),
            conversationLength: conversationTurnCount,
            environmentBrightness: environmentBrightness,
            characterPosition: characterPos,
            distanceToUser: distanceToUser,
            objectsNearby: [],
            sceneComplexity: 0.5,
            recentActivityLevel: 0.5
        )
        
        // Build action from commands
        var action = BehaviorAction()
        let commands = positionController.parseCommands(from: llmResponse)
        
        for command in commands {
            switch command {
            case .moveTo(let from, let to, _):
                action.movementDelta = to - from
            case .move(let x, let y, let z):
                action.movementDelta = SIMD3<Float>(x, y, z) - characterPos
            case .moveRelative(let x, let y, let z):
                action.movementDelta = SIMD3<Float>(x, y, z)
            case .lookAt(let x, let y, let z):
                action.lookTarget = SIMD3<Float>(x, y, z)
            case .pose(let poseType, _):
                action.skeletalPose = poseType.rawValue
            case .rotate(yaw: _, pitch: _, roll: _):
                // Rotation not recorded in training data
                break
            case .scale(_):
                // Scale not recorded in training data
                break
            case .blendShape(name: _, value: let value):
                action.blendShapes["blendShape"] = value
            case .playAnimation(name: let name, loop: let loop):
                // Animation events omitted from training data
                break
            case .stopAnimation:
                // Stop animation omitted from training data
                break
            case .reset:
                // Reset omitted from training data
                break
            }
        }
        
        // Estimate outcome (will be updated when user provides feedback)
        let outcome = BehaviorOutcome(
            reward: userSentiment > 0 ? 0.5 : 0.0,
            userFeedback: nil,
            engagementLevel: 0.6,
            conversationContinued: true
        )
        
        // Record sample
        trainer.recordBehaviorSample(context: context, action: action, outcome: outcome)
    }
    
    public func stop() {
        print("Stopping ConversationManager...")
        currentLLMTask?.cancel(); currentLLMTask = nil
        speech.stopRecording()
        tts.stop()
    }
    
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        print("Pausing ConversationManager...")
        
        // Cancel ongoing LLM task
        currentLLMTask?.cancel()
        currentLLMTask = nil
        
        // Stop speech recognition
        speech.stopRecording()
        
        // Stop TTS
        tts.stop()
        
        // Stop lip sync
        lipSync.stopLipSync()
        
        // Update UI state
        isGenerating = false
    }
    
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        print("Resuming ConversationManager...")
        
        // Restart speech recognition if authorized
        if speech.isAuthorized {
            speech.start()
        }
    }
}
