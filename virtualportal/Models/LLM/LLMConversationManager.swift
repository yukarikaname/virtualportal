//
//  LLMConversationManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import Foundation
import Combine

/// Manages LLM processing, prompt building, and response streaming
@MainActor
public final class LLMConversationManager {
    public static let shared = LLMConversationManager()

    private let llm = FoundationLLM()
    private let memoryManager = MemoryManager.shared
    private let vlmManager = VLMModelManager.shared

    @Published public private(set) var lastLLMResponse: String = ""

    private var currentLLMTask: Task<Void, Never>? = nil

    private init() {}

    public func generateResponse(userText: String, visionContext: String) async -> String {
        let prompt = buildPrompt(user: userText, vision: visionContext)

        // Cancel any existing task
        currentLLMTask?.cancel()

        let accumulator = ResponseAccumulator()
        await accumulator.accumulateResponse(prompt: prompt, llm: llm) { _, _ in }
        let raw = await accumulator.getAccumulatedResponse()
        return sanitizeResponse(raw)
    }

    /// Stream a response from the LLM for the given prompt
    func streamResponse(prompt: String) async -> String {
        let accumulator = ResponseAccumulator()
        await accumulator.accumulateResponse(prompt: prompt, llm: llm) { _, _ in }
        let raw = await accumulator.getAccumulatedResponse()
        return sanitizeResponse(raw)
    }

    /// Stream a response from the LLM with user text and vision context
    public func streamResponse(userText: String, visionContext: String, onChunk: @escaping @Sendable (String, Bool) -> Void) async {
        let prompt = buildPrompt(user: userText, vision: visionContext)

        // Cancel any existing task
        currentLLMTask?.cancel()

        let accumulator = ResponseAccumulator()
        let task = Task {
            await accumulator.accumulateResponse(prompt: prompt, llm: llm) { [weak self] (chunk: String, finished: Bool) in
                guard let self else { return }

                onChunk(chunk, finished)

                if finished {
                    // Update the last response
                    Task {
                        let finalResponse = sanitizeResponse(await accumulator.getAccumulatedResponse())
                        await MainActor.run {
                            self.lastLLMResponse = finalResponse
                        }
                        print("LLM response complete")

                        // Process memory changes and VLM prompts
                        Task.detached { [weak self] in
                            guard let self else { return }
                            await self.processResponseCommands(userText: userText, response: finalResponse)
                        }
                    }
                }
            }
        }

        self.currentLLMTask = task
    }

    private func processResponseCommands(userText: String, response: String) async {
        // Let the MemoryManager consider adding or deleting memories
        await MemoryManager.shared.considerMemoryChange(triggerUserText: userText, llmResponse: response)

        // Allow the LLM to set a VLM prompt using a token like [VLM_PROMPT:...]
        if let range = response.range(of: #"\[VLM_PROMPT:(.*?)\]"#, options: .regularExpression) {
            let content = response[range].replacingOccurrences(of: "[VLM_PROMPT:", with: "").replacingOccurrences(of: "]", with: "")
            let _ = VLMModelManager.shared.setPrompt(String(content))
            print("[LLMConversationManager] VLM prompt set: \(content)")
        }
    }

    private func buildPrompt(user: String, vision: String) -> String {
        var lines: [String] = []

        let characterPersonality = UserDefaults.standard.string(forKey: "characterPersonality") ?? ""
        let extraPrompt = UserDefaults.standard.string(forKey: "extraLLMPrompt") ?? ""
        
        lines.append("You are an AR character in the user's space.")
        if !characterPersonality.isEmpty {
            lines.append("Personality: \(characterPersonality)")
        }
        if !extraPrompt.isEmpty {
            lines.append(extraPrompt)
        }

        if !vision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("You see: \(vision)")
        }

        lines.append("User: \(user)")
        lines.append("")
        lines.append("RULES:")
        lines.append("- Respond as yourself (use 'I')")
        lines.append("- Be conversational and brief (1-2 sentences)")
        lines.append("- NO emojis or emoticons")
        lines.append("")
        lines.append("ACTIONS (optional):")
        lines.append("[ACTION:pose,wave] [ACTION:pose,happy] [ACTION:pose,think]")
        lines.append("[ACTION:move,x,y,z] [ACTION:look,user] [ACTION:expression,smile]")
        lines.append("")
        lines.append("Respond:")

        return lines.joined(separator: "\n")
    }

    // MARK: - SSML Conversion
    
    /// Convert a response with emphasis markers to SSML
    /// Supports markers like: *important*, **very important**, _soft_, etc.
    public func convertToSSML(_ text: String) -> String {
        var result = text
        
        // Handle **bold** as strong emphasis
        result = result.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "<emphasis level=\"strong\">$1</emphasis>",
            options: .regularExpression
        )
        
        // Handle *emphasis*
        result = result.replacingOccurrences(
            of: "(?<!\\*)\\*([^*]+)\\*(?!\\*)",
            with: "<emphasis level=\"moderate\">$1</emphasis>",
            options: .regularExpression
        )
        
        // Handle _soft_ as reduced emphasis
        result = result.replacingOccurrences(
            of: "_([^_]+)_",
            with: "<emphasis level=\"reduced\">$1</emphasis>",
            options: .regularExpression
        )
        
        return "<?xml version=\"1.0\"?><speak>\(result)</speak>"
    }
    
    /// Generate conversational SSML with natural prosody
    /// - Parameters:
    ///   - text: The text to speak
    ///   - tone: "friendly", "serious", "excited", "calm"
    public func generateConversationalSSML(_ text: String, tone: String = "friendly") -> String {
        let builder = SSMLBuilder()
        
        switch tone {
        case "friendly":
            return builder
                .pitch("high", content: text)
                .build()
                
        case "serious":
            return builder
                .rate("slow", content: text)
                .pitch("low", content: text)
                .build()
                
        case "excited":
            return builder
                .rate("fast", content: text)
                .pitch("high", content: text)
                .volume("loud", content: text)
                .build()
                
        case "calm":
            return builder
                .rate("slow", content: text)
                .pitch("medium", content: text)
                .volume("soft", content: text)
                .build()
                
        default:
            return builder.text(text).build()
        }
    }

    // MARK: - Sanitization
    /// Remove emojis/pictographs, collapse whitespace, dedupe repeats, and limit to 2 concise sentences.
    nonisolated private func sanitizeResponse(_ text: String) -> String {
        // Strip emojis and symbols commonly in extended Unicode ranges
        let patterns: [String] = [
            "[\\u{1F300}-\\u{1F9FF}]", // Misc symbols & pictographs
            "[\\u{1FA70}-\\u{1FAFF}]", // Symbols & Pictographs Extended-A
            "[\\u{2600}-\\u{26FF}]",   // Misc symbols
            "[\\u{2700}-\\u{27BF}]"    // Dingbats
        ]
        var s = text
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }

        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on sentence delimiters and dedupe consecutive identical sentences
        let parts = s.split(whereSeparator: { ".?!".contains($0) })
        var unique: [String] = []
        var last: String?
        for raw in parts {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            if sentence.isEmpty { continue }
            if last != sentence { unique.append(sentence); last = sentence }
            if unique.count >= 2 { break }
        }
        if unique.isEmpty { unique = [s] }
        var result = unique.joined(separator: ". ")

        // Remove consecutive duplicate words
        let words = result.split(separator: " ")
        var dedupWords: [Substring] = []
        var prev: Substring?
        for w in words {
            if prev != w { dedupWords.append(w); prev = w }
        }
        result = dedupWords.joined(separator: " ")

        // Final length guard
        return String(result.prefix(240))
    }

    public func cancelCurrentTask() {
        currentLLMTask?.cancel()
        currentLLMTask = nil
    }

    public func decideWhetherToSpeak(vision: String) async -> (shouldSpeak: Bool, utterance: String?)? {
        // Build a short decision prompt requesting JSON-like output
        let prompt = """
        You are an assistant deciding whether the AR character should say something based on the following visual observation (short):
        """
        + "\n\nVISION: \(vision)\n\n"
        + "Return a SINGLE LINE JSON object with keys: speak (true/false) and utterance (a short suggested line or empty). Example: {\"speak\": true, \"utterance\": \"I see a person nearby.\"} \nRespond ONLY with the JSON object. Do NOT include emojis, emoticons, or any pictorial glyphs in the JSON or the utterance field; use plain text only."

        if let decisionText = await llm.generateResponse(of: prompt) {
            let lower = decisionText.lowercased()
            let shouldSpeak: Bool
            if lower.contains("\"speak\": false") || lower.contains("\"speak\":false") || lower.contains("speak: false") {
                shouldSpeak = false
            } else if lower.contains("\"speak\": true") || lower.contains("\"speak\":true") || lower.contains("speak: true") {
                shouldSpeak = true
            } else {
                // Fallback heuristic: speak if decisionText contains 'yes' or 'speak'
                shouldSpeak = lower.contains("yes") || lower.contains("speak")
            }

            // Try to extract utterance field
            var utterance: String? = nil
            if let range = decisionText.range(of: "\"utterance\":") {
                let after = decisionText[range.upperBound...]
                if let firstQuote = after.firstIndex(of: "\""), let lastQuote = after[firstQuote...].firstIndex(of: "\""), lastQuote > firstQuote {
                    let start = decisionText.index(after: firstQuote)
                    if let end = decisionText[start...].firstIndex(of: "\"") {
                        utterance = String(decisionText[start..<end])
                    }
                }
            }

            return (shouldSpeak, utterance)
        }

        return nil
    }
}

/// Actor to safely accumulate streaming LLM responses
private actor ResponseAccumulator {
    private var accumulatedResponse = ""

    func accumulateResponse(prompt: String, llm: FoundationLLM, onChunk: @escaping @Sendable (String, Bool) -> Void) async {
        accumulatedResponse = "" // Reset for new response

        await llm.streamResponse(prompt) { [weak self] (chunk: String, finished: Bool) in
            guard let self else { return }
            Task {
                await self.appendChunk(chunk)
                onChunk(chunk, finished)
            }
        }
    }

    private func appendChunk(_ chunk: String) {
        if !chunk.isEmpty {
            accumulatedResponse += (accumulatedResponse.isEmpty ? "" : " ") + chunk
        }
    }

    func getAccumulatedResponse() -> String {
        return accumulatedResponse
    }
}
