//
//  LipSyncMap.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/20/25.
//

import Foundation

/// Maps phonemes to blendshape names for lip sync animation
/// Supports Japanese, Chinese, and English phonemes
public struct LipSyncMap {

    // MARK: - Viseme Types
    public enum Viseme: String, CaseIterable {
        case neutral = "neutral"
        case a = "a"      // ah
        case e = "e"      // eh
        case i = "i"      // ee
        case o = "o"      // oh
        case u = "u"      // oo
        case m = "m"      // m
        case b = "b"      // b/p
        case f = "f"      // f/v
        case l = "l"      // l
        case th = "th"    // th
        case w = "w"      // w
    }


    // MARK: - Phoneme to Viseme Mappings

    /// English phoneme to viseme mapping
        nonisolated(unsafe) static let englishPhonemeMap: [String: Viseme] = [
        // Vowels
        "a": .a, "æ": .a, "ɑ": .a, "ɔ": .o, "o": .o, "ʊ": .u, "u": .u,
        "ɛ": .e, "ɪ": .i, "i": .i, "ʌ": .a, "ə": .e, "ɚ": .e,

        // Diphthongs
        "aɪ": .i, "aʊ": .o, "ɔɪ": .o, "eɪ": .e, "oʊ": .o, "ju": .u,

        // Consonants
        "m": .m, "b": .b, "p": .b, "f": .f, "v": .f,
        "θ": .th, "ð": .th, "s": .e, "z": .e, "ʃ": .e, "ʒ": .e,
        "tʃ": .e, "dʒ": .e, "k": .a, "g": .a, "ŋ": .a,
        "l": .l, "r": .e, "w": .w, "j": .i, "h": .a
    ]

    /// Japanese phoneme to viseme mapping (hiragana/katakana)
    nonisolated(unsafe) private static let japanesePhonemeMap: [String: Viseme] = [
        // Vowels
        "a": .a, "i": .i, "u": .u, "e": .e, "o": .o,

        // Consonants
        "k": .a, "s": .e, "t": .e, "n": .a, "h": .a, "m": .m,
        "y": .i, "r": .e, "w": .u, "g": .a, "z": .e, "d": .e,
        "b": .b, "p": .b, "f": .f, "v": .f, "j": .e, "ch": .e,
        "ts": .e, "sh": .e, "dz": .e
    ]

    /// Chinese phoneme to viseme mapping (pinyin)
    nonisolated(unsafe) private static let chinesePhonemeMap: [String: Viseme] = [
        // Vowels
        "a": .a, "e": .e, "i": .i, "o": .o, "u": .u, "ü": .u,

        // Finals
        "ai": .a, "ei": .e, "ao": .a, "ou": .o, "ia": .a, "ie": .e,
        "ua": .a, "uo": .o, "üe": .e, "iao": .a, "iou": .o, "uai": .a,
        "uei": .e,

        // Consonants
        "b": .b, "p": .b, "m": .m, "f": .f, "d": .e, "t": .e,
        "n": .a, "l": .l, "g": .a, "k": .a, "h": .a, "j": .i,
        "q": .i, "x": .e, "zh": .e, "ch": .e, "sh": .e, "r": .e,
        "z": .e, "c": .e, "s": .e
    ]

    /// Korean phoneme to viseme mapping (Hangul)
    nonisolated(unsafe) private static let koreanPhonemeMap: [String: Viseme] = [
        // Vowels (모음)
        "ㅏ": .a, "ㅑ": .a, "ㅓ": .e, "ㅕ": .e, "ㅗ": .o, "ㅛ": .o,
        "ㅜ": .u, "ㅠ": .u, "ㅡ": .u, "ㅣ": .i, "ㅐ": .e, "ㅒ": .e,
        "ㅔ": .e, "ㅖ": .e, "ㅘ": .a, "ㅙ": .e, "ㅚ": .o, "ㅝ": .u,
        "ㅞ": .e, "ㅟ": .u, "ㅢ": .i,

        // Consonants (자음)
        "ㄱ": .a, "ㄲ": .a, "ㅋ": .a, "ㄷ": .e, "ㄸ": .e, "ㅌ": .e,
        "ㅂ": .b, "ㅃ": .b, "ㅍ": .b, "ㅈ": .e, "ㅉ": .e, "ㅊ": .e,
        "ㅅ": .e, "ㅆ": .e, "ㅎ": .a, "ㅁ": .m, "ㄴ": .a, "ㄹ": .l,
        "ㅇ": .a,

        // Common syllable combinations
        "가": .a, "나": .a, "다": .e, "라": .a, "마": .a, "바": .a, "사": .e,
        "아": .a, "자": .a, "차": .e, "카": .a, "타": .e, "파": .a, "하": .a
    ]

    // MARK: - Blendshape Names

    /// Maps visemes to blendshape names used in the 3D model
    nonisolated(unsafe) private static let visemeToBlendshape: [Viseme: String] = [
        .neutral: "neutral",
        .a: "mouth_open_wide",      // Wide open mouth for 'ah'
        .e: "mouth_open_narrow",    // Narrow open for 'eh'
        .i: "mouth_smile_wide",     // Wide smile for 'ee'
        .o: "mouth_round",          // Rounded mouth for 'oh'
        .u: "mouth_pucker",         // Puckered lips for 'oo'
        .m: "mouth_closed_lips",    // Closed lips with slight protrusion
        .b: "mouth_closed_teeth",   // Closed with teeth showing
        .f: "mouth_teeth_upper",    // Upper teeth on lower lip
        .l: "mouth_tongue_up",      // Tongue against roof of mouth
        .th: "mouth_tongue_out",    // Tongue between teeth
        .w: "mouth_small_round"     // Small rounded opening
    ]

    /// Default numeric blendshape values for each viseme.
    /// These are normalized values (0.0 - 1.0) that represent a reasonable
    /// default intensity for the corresponding blendshape. Models may require
    /// different scalings; treat these as defaults that can be adjusted per-model.
    nonisolated(unsafe) private static let visemeToBlendshapeValue: [Viseme: Float] = [
        .neutral: 0.0,
        .a: 0.95,
        .e: 0.70,
        .i: 0.60,
        .o: 0.90,
        .u: 0.85,
        .m: 0.15,
        .b: 0.12,
        .f: 0.25,
        .l: 0.20,
        .th: 0.18,
        .w: 0.50
    ]

    // MARK: - Blendshape Value Accessors

    /// Get the default numeric blendshape value for a given `Viseme`.
    public static func blendshapeValue(for viseme: Viseme) -> Float {
        return visemeToBlendshapeValue[viseme] ?? 0.0
    }

    /// Get the default numeric blendshape value for a phoneme (script-agnostic lookup).
    public static func blendshapeValue(for phoneme: String) -> Float {
        let viseme = self.viseme(for: phoneme)
        return blendshapeValue(for: viseme)
    }

    // MARK: - Public Methods

    /// Get viseme for a phoneme using available language maps.
    /// Tries Korean map (for Hangul), then Chinese, Japanese, then English fallbacks.
    public static func viseme(for phoneme: String) -> Viseme {
        // Direct Korean lookup (Hangul characters / jamo)
        if koreanPhonemeMap[phoneme] != nil {
            return koreanPhonemeMap[phoneme] ?? .neutral
        }

        let lower = phoneme.lowercased()

        if let c = chinesePhonemeMap[lower] { return c }
        if let j = japanesePhonemeMap[lower] { return j }
        if let e = englishPhonemeMap[lower] { return e }

        return .neutral
    }

    /// Get blendshape name for a viseme
    public static func blendshapeName(for viseme: Viseme) -> String {
        return visemeToBlendshape[viseme] ?? "neutral"
    }

    /// Get blendshape name for a phoneme (script-agnostic)
    public static func blendshapeName(for phoneme: String) -> String {
        let viseme = self.viseme(for: phoneme)
        return blendshapeName(for: viseme)
    }

    // NOTE: Language detection and related helpers were intentionally removed from
    // `LipSyncMap`. Language detection should be performed by the LLM/Conversation
    // layer (e.g. `ConversationManager`) and the resulting `Language` value passed
    // explicitly to the lipsync pipeline. This keeps phoneme mapping deterministic
    // and avoids duplicated detection logic.

    /// Convert text to phonemes (simplified).
    /// Script detection rules:
    /// - If text contains Hiragana/Katakana -> treat as Japanese (may call LLM for Kanji)
    /// - Else if text contains any CJK Unified Ideographs (Han characters) -> treat as Chinese (LLM used for Hanzi)
    /// - Else if text contains Hangul -> treat as Korean
    /// - Otherwise treat as English
    public static func phonemes(from text: String) async -> [String] {
        // Quick script detection
        if text.containsHiragana || text.containsKatakana {
            return await japanesePhonemes(from: text)
        }

        if text.containsCJKUnifiedIdeograph {
            return await chinesePhonemes(from: text)
        }

        if text.containsHangul {
            return koreanPhonemes(from: text)
        }

        return englishPhonemes(from: text)
    }

    // MARK: - Private Phoneme Extraction Methods

    private static func englishPhonemes(from text: String) -> [String] {
        // Simplified English phoneme extraction
        // In a real implementation, you'd use a proper phoneme dictionary or library
        var phonemes: [String] = []
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)

        for word in words {
            // Very basic mapping - this should be replaced with proper phonetics
            for char in word {
                switch char {
                case "a", "o", "u":
                    phonemes.append("a")
                case "e":
                    phonemes.append("e")
                case "i":
                    phonemes.append("i")
                case "m":
                    phonemes.append("m")
                case "b", "p":
                    phonemes.append("b")
                case "f", "v":
                    phonemes.append("f")
                case "l":
                    phonemes.append("l")
                case "w":
                    phonemes.append("w")
                default:
                    // Ignore unsupported characters (punctuation, emoji, etc.)
                    break
                }
            }
        }

        return phonemes
    }
    
    private static func hiraganaToVowel(_ char: Character) -> String {
        switch char {
        // --- A ---
        case "あ","か","さ","た","な","は","ま","や","ら","わ",
             "が","ざ","だ","ば","ぱ",
             "ぁ","ゃ":
            return "a"

        // --- I ---
        case "い","き","し","ち","に","ひ","み","り",
             "ぎ","じ","ぢ","び","ぴ",
             "ぃ":
            return "i"

        // --- U ---
        case "う","く","す","つ","ぬ","ふ","む","ゆ","る",
             "ぐ","ず","づ","ぶ","ぷ",
             "ぅ","ゅ":
            return "u"

        // --- E ---
        case "え","け","せ","て","ね","へ","め","れ",
             "げ","ぜ","で","べ","ぺ",
             "ぇ":
            return "e"

        // --- O ---
        case "お","こ","そ","と","の","ほ","も","よ","ろ","を",
             "ご","ぞ","ど","ぼ","ぽ",
             "ぉ","ょ":
            return "o"

        default:
            return "a"
        }
    }

    private static func japanesePhonemes(from text: String) async -> [String] {
        var phonemes: [String] = []

        for char in text {
            // HIRAGANA
            if ("\u{3040}"..."\u{309F}").contains(char) {
                phonemes.append(hiraganaToVowel(char))
                continue
            }

            // KATAKANA → convert to hiragana, then map
            if ("\u{30A0}"..."\u{30FF}").contains(char) {
                let hira = katakanaToHiragana(char)
                phonemes.append(hiraganaToVowel(hira))
                continue
            }

            // KANJI
            if ("\u{4E00}"..."\u{9FFF}").contains(char) {
                let phoneme = await kanjiToPhoneme(String(char))
                phonemes.append(phoneme)
                continue
            }

            // ROMAJI / Other letters
            if char.isLetter {
                phonemes.append("a") // simplified fallback
            }
        }

        return phonemes
    }
    
    private static func katakanaToHiragana(_ char: Character) -> Character {
        guard let scalar = char.unicodeScalars.first else { return char }
        let v = scalar.value

        // Katakana block → shift -0x60 to Hiragana block
        if (0x30A0...0x30FF).contains(v),
           let hira = UnicodeScalar(v - 0x60) {
            return Character(hira)
        }

        return char
    }


    private static func chinesePhonemes(from text: String) async -> [String] {
        // Use LLM to convert Chinese characters to phonemes
        var phonemes: [String] = []

        for char in text {
            if char >= "\u{4E00}" && char <= "\u{9FFF}" { // Chinese characters
                // Use LLM to determine the phoneme for the Chinese character
                let phoneme = await hanziToPhoneme(String(char))
                phonemes.append(phoneme)
            } else if char.isLetter {
                // Pinyin or other letters - map to basic phonemes
                let lowerChar = char.lowercased()
                switch lowerChar {
                case "a", "o":
                    phonemes.append("a")
                case "e":
                    phonemes.append("e")
                case "i":
                    phonemes.append("i")
                case "u", "ü":
                    phonemes.append("u")
                case "b", "p":
                    phonemes.append("b")
                case "m":
                    phonemes.append("m")
                case "f":
                    phonemes.append("f")
                case "d", "t":
                    phonemes.append("e")
                case "n":
                    phonemes.append("a")
                case "l":
                    phonemes.append("l")
                case "g", "k", "h":
                    phonemes.append("a")
                case "j", "q", "x":
                    phonemes.append("i")
                case "z", "c", "s", "zh", "ch", "sh", "r":
                    phonemes.append("e")
                default:
                    phonemes.append("a")
                }
            }
        }

        return phonemes
    }

    private static func koreanPhonemes(from text: String) -> [String] {
        // Korean phoneme extraction from Hangul text
        var phonemes: [String] = []

        for char in text {
            if char >= "\u{AC00}" && char <= "\u{D7AF}" { // Hangul syllables
                // Decompose Hangul syllable into jamo (consonant + vowel + optional consonant)
                let syllableIndex = Int(char.unicodeScalars.first!.value - 0xAC00)

                // Extract vowel (jungseong)
                let vowelIndex = (syllableIndex / 28) % 21
                let vowels: [String] = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ"]

                if vowelIndex < vowels.count {
                    phonemes.append(vowels[vowelIndex])
                }

                // Extract final consonant (jongseong) if present
                let finalIndex = syllableIndex % 28
                if finalIndex > 0 {
                    let finals: [String] = ["ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
                    if finalIndex - 1 < finals.count {
                        phonemes.append(finals[finalIndex - 1])
                    }
                }
            } else if char >= "\u{1100}" && char <= "\u{11FF}" { // Individual jamo
                // Direct jamo characters
                phonemes.append(String(char))
            } else if char.isLetter {
                // Roman characters or other letters
                phonemes.append("a") // Simplified
            }
        }

        return phonemes
    }

    /// Use LLM to convert Kanji character to phoneme
    private static func kanjiToPhoneme(_ kanji: String) async -> String {
        let llm = FoundationLLM()

        // Use LLM to determine the phoneme for the Japanese Kanji character
        let prompt = """
        Convert this Japanese Kanji character to its most common phoneme (vowel sound) for lip sync animation.
        Return only a single vowel: 'a', 'i', 'u', 'e', or 'o'.

        Kanji: \(kanji)

        Consider the most common reading and return the primary vowel sound.
        """

        if let response = await llm.generateResponse(of: prompt) {
            let cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Extract the first vowel found in the response
            for char in cleanResponse {
                if "aiueo".contains(char) {
                    return String(char)
                }
            }
        }

        // Fallback to 'a' if LLM fails or returns unexpected response
        print("Unhandled case in kanjiToPhoneme")
        return "a"
    }

    /// Use LLM to convert Hanzi character to phoneme
    private static func hanziToPhoneme(_ hanzi: String) async -> String {
        let llm = FoundationLLM()

        // Use LLM to determine the phoneme for the Chinese character
        let prompt = """
        Convert this Chinese Hanzi character to its most common phoneme (vowel sound) for lip sync animation.
        Return only a single vowel: 'a', 'i', 'u', 'e', or 'o'.

        Hanzi: \(hanzi)

        Consider the most common pinyin pronunciation and return the primary vowel sound.
        """

        if let response = await llm.generateResponse(of: prompt) {
            let cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Extract the first vowel found in the response
            for char in cleanResponse {
                if "aiueo".contains(char) {
                    return String(char)
                }
            }
        }

        // Fallback to 'a' if LLM fails or returns unexpected response
        print("Unhandled hanziToPhoneme")
        return "a"
    }
}

// MARK: - String script detection helpers
private extension String {
    var containsHiragana: Bool {
        for ch in self {
            if ("\u{3040}"..."\u{309F}").contains(ch) { return true }
        }
        return false
    }

    var containsKatakana: Bool {
        for ch in self {
            if ("\u{30A0}"..."\u{30FF}").contains(ch) { return true }
        }
        return false
    }

    var containsCJKUnifiedIdeograph: Bool {
        for ch in self {
            if ("\u{4E00}"..."\u{9FFF}").contains(ch) { return true }
        }
        return false
    }

    var containsHangul: Bool {
        for ch in self {
            if ("\u{AC00}"..."\u{D7AF}").contains(ch) { return true }
        }
        return false
    }
}

