//
//  SSMLBuilder.swift
//  virtualportal
//
//  Created by Yukari Kaname on 12/5/25.
//

import Foundation

/// SSML (Speech Synthesis Markup Language) builder for advanced speech control
/// Supports prosody, voice, emphasis, pauses, and more
///
/// Personal Voice Compatibility:
/// - Personal Voice works with SSML on iOS 16.0+
/// - The system applies Personal Voice to the entire utterance while respecting SSML prosody markup
/// - When Personal Voice is enabled and available, it's automatically applied before SSML processing
/// - SSML prosody controls (rate, pitch, volume) work alongside Personal Voice
///
/// Example with Personal Voice:
/// ```swift
/// let ssml = SSMLBuilder()
///     .pitch("high", content: "This is spoken with Personal Voice")
///     .pause(duration: 500)
///     .rate("slow", content: "Speaking slowly")
///     .build()
/// // TextToSpeechManager will use Personal Voice with SSML prosody applied
/// ```
public class SSMLBuilder {
    private var elements: [String] = []
    
    public init() {}
    
    /// Add plain text
    @discardableResult
    public func text(_ content: String) -> SSMLBuilder {
        elements.append(escapeXML(content))
        return self
    }
    
    /// Add a break (pause)
    /// - Parameters:
    ///   - duration: Duration in milliseconds (e.g., 500)
    @discardableResult
    public func pause(duration: Int) -> SSMLBuilder {
        elements.append("<break time=\"\(duration)ms\"/>")
        return self
    }
    
    /// Add a break by strength
    /// - Parameters:
    ///   - strength: "none", "x-weak", "weak", "medium", "strong", "x-strong"
    @discardableResult
    public func pause(strength: String = "medium") -> SSMLBuilder {
        elements.append("<break strength=\"\(strength)\"/>")
        return self
    }
    
    /// Modify speech rate
    /// - Parameters:
    ///   - rate: "x-slow", "slow", "medium", "fast", "x-fast", or percentage like "80%"
    @discardableResult
    public func rate(_ rate: String, content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<prosody rate=\"\(rate)\">\(escaped)</prosody>")
        return self
    }
    
    /// Modify pitch
    /// - Parameters:
    ///   - pitch: "x-low", "low", "medium", "high", "x-high", or relative like "+10%"
    @discardableResult
    public func pitch(_ pitch: String, content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<prosody pitch=\"\(pitch)\">\(escaped)</prosody>")
        return self
    }
    
    /// Modify volume
    /// - Parameters:
    ///   - volume: "silent", "x-soft", "soft", "medium", "loud", "x-loud", or dB like "+6dB"
    @discardableResult
    public func volume(_ volume: String, content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<prosody volume=\"\(volume)\">\(escaped)</prosody>")
        return self
    }
    
    /// Apply emphasis
    /// - Parameters:
    ///   - level: "strong", "moderate", "reduced"
    @discardableResult
    public func emphasis(_ level: String = "moderate", content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<emphasis level=\"\(level)\">\(escaped)</emphasis>")
        return self
    }
    
    /// Spell out text letter by letter
    @discardableResult
    public func spellOut(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"characters\">\(escaped)</say-as>")
        return self
    }
    
    /// Interpret as a date
    /// - Parameters:
    ///   - content: Date string
    ///   - format: "mdy", "dmy", "ymd", "md", "dm", "my", "ym"
    @discardableResult
    public func date(_ content: String, format: String = "mdy") -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"date\" format=\"\(format)\">\(escaped)</say-as>")
        return self
    }
    
    /// Interpret as time
    @discardableResult
    public func time(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"time\" format=\"hms12\">\(escaped)</say-as>")
        return self
    }
    
    /// Interpret as a number
    @discardableResult
    public func number(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"number\">\(escaped)</say-as>")
        return self
    }
    
    /// Interpret as currency
    @discardableResult
    public func currency(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"currency\">\(escaped)</say-as>")
        return self
    }
    
    /// Interpret as telephone number
    @discardableResult
    public func telephone(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<say-as interpret-as=\"telephone\">\(escaped)</say-as>")
        return self
    }
    
    /// Add audio with fallback text
    /// - Parameters:
    ///   - url: URL to audio file
    ///   - fallback: Text to speak if audio cannot be played
    @discardableResult
    public func audio(url: String, fallback: String) -> SSMLBuilder {
        let escaped = escapeXML(fallback)
        elements.append("<audio src=\"\(url)\">\(escaped)</audio>")
        return self
    }
    
    /// Set voice properties
    /// - Parameters:
    ///   - name: Voice name or language (e.g., "en-US", "fr-FR")
    ///   - gender: "male", "female", or nil for any
    ///   - age: Age in years, or nil for any
    @discardableResult
    public func voice(name: String? = nil, gender: String? = nil, age: Int? = nil, content: String) -> SSMLBuilder {
        var attributes = ""
        if let name = name {
            attributes += "name=\"\(name)\" "
        }
        if let gender = gender {
            attributes += "gender=\"\(gender)\" "
        }
        if let age = age {
            attributes += "age=\"\(age)\" "
        }
        
        let escaped = escapeXML(content)
        elements.append("<voice \(attributes)>\(escaped)</voice>")
        return self
    }
    
    /// Add a sentence with optional xml:lang attribute
    /// - Parameters:
    ///   - content: The sentence text
    ///   - lang: Language code (e.g., "en-US", "fr-FR")
    @discardableResult
    public func sentence(_ content: String, lang: String? = nil) -> SSMLBuilder {
        let escaped = escapeXML(content)
        if let lang = lang {
            elements.append("<s xml:lang=\"\(lang)\">\(escaped)</s>")
        } else {
            elements.append("<s>\(escaped)</s>")
        }
        return self
    }
    
    /// Add a paragraph
    @discardableResult
    public func paragraph(_ content: String) -> SSMLBuilder {
        let escaped = escapeXML(content)
        elements.append("<p>\(escaped)</p>")
        return self
    }
    
    /// Build the final SSML string
    public func build() -> String {
        return "<?xml version=\"1.0\"?><speak>\(elements.joined())</speak>"
    }
    
    /// Escape XML special characters
    private func escapeXML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Common SSML Presets
public extension SSMLBuilder {
    /// Create an excited greeting
    static func excitedGreeting(name: String) -> String {
        return SSMLBuilder()
            .text("Hello, ")
            .emphasis("strong", content: name)
            .text("! ")
            .pause(duration: 200)
            .text("It's so great to see you!")
            .build()
    }
    
    /// Create a thoughtful response
    static func thoughtfulResponse(_ content: String) -> String {
        return SSMLBuilder()
            .pause(strength: "medium")
            .rate("slow", content: content)
            .build()
    }
    
    /// Create a question with rising intonation
    static func question(_ content: String) -> String {
        return SSMLBuilder()
            .pitch("high", content: content)
            .text("?")
            .build()
    }
    
    /// Create a whispered text effect
    static func whisper(_ content: String) -> String {
        return SSMLBuilder()
            .volume("x-soft", content: content)
            .rate("slow", content: content)
            .build()
    }
}
