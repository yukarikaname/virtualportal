//
//  MemoryManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import Foundation
import Combine

public struct MemoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@MainActor
public final class MemoryManager: ObservableObject {
    public static let shared = MemoryManager()

    @Published public private(set) var memories: [MemoryEntry] = []

    private let storageKey = "virtualportal.characterMemories"
    private let llm = FoundationLLM()

    private init() {
        load()
    }

    // MARK: - Persistence
    private func storageURL() -> URL? {
        let fm = FileManager.default
        do {
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = appSupport.appendingPathComponent("virtualportal", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.appendingPathComponent("memories.json")
        } catch {
            return nil
        }
    }

    private func load() {
        if let url = storageURL(), let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: data) {
                // Filter out blank memories that may have been saved previously
                let filtered = decoded.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                self.memories = filtered
                if filtered.count != decoded.count { save() }
                return
            }
        }
    }

    private func save() {
        if let url = storageURL() {
            if let data = try? JSONEncoder().encode(memories) {
                try? data.write(to: url, options: [.atomic])
            }
        } else {
            if let data = try? JSONEncoder().encode(memories) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }

    // MARK: - Public API
    public func addMemory(_ text: String) {
        let clean = sanitize(text)
        guard !clean.isEmpty else { return }
        let entry = MemoryEntry(text: clean)
        memories.append(entry)
        save()
        NotificationCenter.default.post(name: Notification.Name("virtualportal.memoryAdded"), object: entry)
    }

    public func deleteMemory(id: UUID) {
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            let removed = memories.remove(at: idx)
            save()
            NotificationCenter.default.post(name: Notification.Name("virtualportal.memoryDeleted"), object: removed)
        }
    }

    public func updateMemory(id: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            memories[idx].text = trimmed
            save()
            NotificationCenter.default.post(name: Notification.Name("virtualportal.memoryUpdated"), object: memories[idx])
        }
    }

    public func clearMemories() {
        memories.removeAll()
        save()
        NotificationCenter.default.post(name: Notification.Name("virtualportal.memoriesCleared"), object: nil)
    }

    // MARK: - Sanitization
    /// Strip emojis, dedupe consecutive words/sentences, collapse whitespace
    private func sanitize(_ text: String) -> String {
        // Strip emoji ranges
        let patterns: [String] = [
            "[\\u{1F300}-\\u{1F9FF}]",
            "[\\u{1FA70}-\\u{1FAFF}]",
            "[\\u{2600}-\\u{26FF}]",
            "[\\u{2700}-\\u{27BF}]"
        ]
        var s = text
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dedupe consecutive duplicate sentences
        let parts = s.split(whereSeparator: { ".?!".contains($0) })
        var unique: [String] = []
        var last: String?
        for raw in parts {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            if sentence.isEmpty { continue }
            if last != sentence { unique.append(sentence); last = sentence }
            if unique.count >= 3 { break } // cap memories to 3 sentences
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
        return String(result.prefix(240))
    }

    // Let the LLM decide whether to add/delete/ignore a candidate memory.
    public func considerMemoryChange(triggerUserText: String, llmResponse: String?) async {
        guard llm.isAvailable else { return }

        // Build prompt with current memories and the new observation
        var promptLines: [String] = []
        promptLines.append("You are the memory manager for an AR character. Your job is to decide whether a new observation should be added to the character's short-term memory, deleted from memory, or ignored.")
        promptLines.append("Respond with a SINGLE LINE JSON object exactly with keys: action (one of add, delete, none), memory (string for add), id (uuid string to delete or empty), reason (brief). Example: {\\\"action\\\": \\\"add\\\", \\\"memory\\\": \\\"The user likes tea\\\", \\\"id\\\": \\\"\\\", \\\"reason\\\": \\\"New preference mentioned\\\"}")
        promptLines.append("")
        promptLines.append("CURRENT_MEMORIES:")
        if memories.isEmpty {
            promptLines.append("(none)")
        } else {
            for m in memories.suffix(10) { // limit to recent 10
                promptLines.append("")
                promptLines.append("- id: \(m.id.uuidString)" )
                promptLines.append("  text: \(m.text)")
                promptLines.append("  createdAt: \(m.createdAt)")
            }
        }
        promptLines.append("")
        promptLines.append("NEW_OBSERVATION:")
        promptLines.append("User said: \(triggerUserText)")
        if let lr = llmResponse, !lr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptLines.append("")
            promptLines.append("LLM_RESPONSE: \(lr)")
        }

        let prompt = promptLines.joined(separator: "\n")

        guard let decisionText = await llm.generateResponse(of: prompt) else { return }

        let lowered = decisionText.lowercased()
        // Determine action (robust, simple heuristics)
        let action: String
        if lowered.contains("\"action\"") {
            if lowered.contains("\"add\"") {
                action = "add"
            } else if lowered.contains("\"delete\"") {
                action = "delete"
            } else {
                action = "none"
            }
        } else if lowered.contains("add") && lowered.contains("memory") {
            action = "add"
        } else if lowered.contains("delete") && lowered.contains("memory") {
            action = "delete"
        } else {
            action = "none"
        }

        // Extract memory field if present
        var memoryText: String? = nil
        if let range = decisionText.range(of: "\"memory\":") {
            let after = decisionText[range.upperBound...]
            if let firstQuote = after.firstIndex(of: "\"") {
                let rest = after[firstQuote...]
                let start = decisionText.index(after: firstQuote)
                if let end = rest.dropFirst().firstIndex(of: "\"") {
                    memoryText = String(decisionText[start..<end])
                }
            }
        }

        // Extract id field if present
        var idText: String? = nil
        if let range = decisionText.range(of: "\"id\":") {
            let after = decisionText[range.upperBound...]
            if let firstQuote = after.firstIndex(of: "\"") {
                let rest = after[firstQuote...]
                let start = decisionText.index(after: firstQuote)
                if let end = rest.dropFirst().firstIndex(of: "\"") {
                    idText = String(decisionText[start..<end])
                }
            }
        }

        // Apply action
        switch action {
        case "add":
            let textToAdd = memoryText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawText = (textToAdd?.isEmpty ?? true) ? llmResponse ?? triggerUserText : textToAdd!
            let finalText = sanitize(rawText)
            guard !finalText.isEmpty else { return }
            addMemory(finalText)
            print("[MemoryManager] Added memory: \(finalText)")
        case "delete":
            if let idText = idText, let uuid = UUID(uuidString: idText) {
                deleteMemory(id: uuid)
                print("[MemoryManager] Deleted memory id: \(idText)")
            } else if let memoryText = memoryText {
                // Try find by substring
                if let idx = memories.firstIndex(where: { $0.text.localizedCaseInsensitiveContains(memoryText) }) {
                    let removed = memories[idx]
                    memories.remove(at: idx)
                    save()
                    NotificationCenter.default.post(name: Notification.Name("virtualportal.memoryDeleted"), object: removed)
                    print("[MemoryManager] Deleted memory by text match: \(memoryText)")
                }
            } else {
                // No id or memory text provided - do nothing
                print("[MemoryManager] Delete requested but no id/text found in LLM response: \(decisionText)")
            }
        default:
            // none
            print("[MemoryManager] No memory action taken. LLM response: \(decisionText)")
        }
    }
}
//
//  MemoryManager.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/9/25.
//

