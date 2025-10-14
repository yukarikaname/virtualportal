//
//  FoundationLLM.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

import FoundationModels
import Foundation

public class FoundationLLM {
    
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
        } catch {
            print("Error generating response: \(error)")
            return nil
        }
    }
    
    /// Stream tokens and emit chunks when a comma or period is encountered. Callback: (chunk, finished)
    public func streamResponse(_ message: String, onChunk: @escaping @Sendable (String, Bool) -> Void) async {
        guard isAvailable else {
            print("Foundation Model not available, using fallback response")
            let fallback = "I'm sorry, the AI model is currently not available on this device."
            onChunk(fallback, true)
            return
        }
        let session = LanguageModelSession()
        var buffer = ""
        do {
            for try await token in session.streamResponse(to: message) {
                buffer += token.content
                if let last = buffer.last, ",.".contains(last) {
                    let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !chunk.isEmpty { onChunk(chunk, false) }
                    buffer = ""
                }
            }
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { onChunk(tail, false) }
            onChunk("", true)
        } catch {
            print("Error streaming response: \(error)")
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { 
                onChunk(tail, false) 
                onChunk("I encountered an error while processing your request.", true)
            } else { 
                onChunk("I encountered an error while processing your request.", true) 
            }
        }
    }
}
