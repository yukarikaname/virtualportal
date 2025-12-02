//
//  FoundationLLM.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

import FoundationModels
import Foundation

public final class FoundationLLM: @unchecked Sendable {
    
    public let model: SystemLanguageModel
    
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }
    
    var isAvailable: Bool {
        switch model.availability {
        case .available:
            return true
        default:
            return false
        }
    }
    
    public func generateResponse(of message: String) async -> String? {
        guard isAvailable else {
            print("Model not available")
            return nil
        }
        
        let session = LanguageModelSession()
        
        do {
            var generatedText = ""
            for try await token in session.streamResponse(to: message) {
                generatedText += token.content
            }
            return generatedText
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            print("Safety guardrails triggered in generateResponse")
            return "This conversation violates Apple's content policy and cannot be completed."
        } catch {
            print("Error generating response: \(error)")
            return nil
        }
    }
    
    /// Stream tokens and emit chunks when a comma or period is encountered. Callback: (chunk, finished)
    /// Stream tokens and emit chunks when a comma or period is encountered.
    /// If the LLM prepends a JSON metadata object at the start of the response
    /// containing a `language` field (e.g. {"language":"japanese"}), this
    /// method will extract it and pass it along with all subsequent chunks.
    /// Callback: (chunk, finished, detectedLanguage)
    public func streamResponse(_ message: String, onChunk: @escaping @Sendable (String, Bool) -> Void) async {
        guard isAvailable else {
            NotificationCenter.default.post(name: Notification.Name("virtualportal.foundationModelUnavailable"), object: nil)
            print("Foundation Model not available")
            let fallback = ""
            onChunk(fallback, true)
            return
        }
        let session = LanguageModelSession()
        var buffer = ""
        do {
            for try await token in session.streamResponse(to: message) {
                buffer += token.content
                if let last = buffer.last, ",.".contains(last) {
                    let chunk = buffer
                    if !chunk.isEmpty { onChunk(chunk, false) }
                    buffer = ""
                }
            }
            let tail = buffer
            if !tail.isEmpty { onChunk(tail, false) }
            onChunk("", true)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            print("Safety guardrails triggered - content policy violation")
            // Send transparent message when guardrails are triggered
            let fallback = "This conversation violates Apple's content policy and cannot be completed."
            onChunk(fallback, false)
            onChunk("", true)
        } catch {
            print("Error streaming response: \(error)")
            // Send empty completion on other errors
            onChunk("", true)
        }
    }
}
