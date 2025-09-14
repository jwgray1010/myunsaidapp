import Foundation
import NaturalLanguage
import QuartzCore
#if canImport(UIKit)
import UIKit
import Contacts
#endif

// MARK: - File-scope static tables (single copy across process)
private let FAST_TYPOS: [String: String] = [
    "hte":"the","teh":"the","thw":"the","thr":"the","tge":"the","tye":"the","tghe":"the","thhe":"the",
    "yuo":"you","yoi":"you","tou":"you","youu":"you","yoh":"you","yok":"you","yoou":"you","oyu":"you",
    "tjis":"this","tjhis":"this","ths":"this","thsi":"this","tihs":"this","thix":"this",
    "waht":"what","hwta":"what","wha":"what","whst":"what","whar":"what","wjat":"what",
    "taht":"that","thta":"that","thqt":"that","thay":"that","thwt":"that",
    "adn":"and","annd":"and","amd":"and","anb":"and",
    "aer":"are","arr":"are","rae":"are","aree":"are",
    "wsa":"was","awsa":"was","ws":"was","waz":"was",
    "wiht":"with","witj":"with","woth":"with","wih":"with","wifh":"with",
    "yuor":"your","yur":"your","yoru":"your","youe":"your","yout":"your",
    "form":"from","fron":"from","fro":"from","fom":"from",
    "ahve":"have","haev":"have","hvae":"have","hae":"have",
    "jsut":"just","jsu":"just","jist":"just","juts":"just",
    "liek":"like","likr":"like","ljke":"like","liekd":"liked",
    "becuase":"because","bcause":"because","beacause":"because","becasue":"because",
    "peopel":"people","poeple":"people","peple":"people",
    "woudl":"would","wolud":"would","wouls":"would",
    "coudl":"could","colud":"could","couls":"could",
    "shoudl":"should","sholud":"should","shoud":"should",
    "abuot":"about","abot":"about","abotu":"about",
    "knwo":"know","konw":"know","kbow":"know","nkow":"know",
    "gonig":"going","giong":"going","goin":"going",
    "relaly":"really","realy":"really","rellay":"really",
    "probaly":"probably","probbaly":"probably","propably":"probably",

    // Contractions - common missing apostrophes
    "youre":"you're","theyre":"they're","were":"we're","hes":"he's","shes":"she's",
    "its":"it's","thats":"that's","whats":"what's","whos":"who's","hows":"how's",
    "wheres":"where's","theres":"there's","heres":"here's","whens":"when's",
    "dont":"don't","cant":"can't","wont":"won't","isnt":"isn't","arent":"aren't",
    "wasnt":"wasn't","werent":"weren't","hasnt":"hasn't","havent":"haven't",
    "hadnt":"hadn't","wouldnt":"wouldn't","couldnt":"couldn't","shouldnt":"shouldn't",
    "didnt":"didn't","doesnt":"doesn't","mustnt":"mustn't","neednt":"needn't",
    "ive":"I've","id":"I'd","ill":"I'll","im":"I'm","youve":"you've",
    "youd":"you'd","youll":"you'll","weve":"we've","wed":"we'd","well":"we'll",
    "theyve":"they've","theyd":"they'd","theyll":"they'll"
]

private let QWERTY_NEIGHBORS: [Character: Set<Character>] = [
    "q":["w","a"],"w":["q","e","a","s"],"e":["w","r","s","d"],
    "r":["e","t","d","f"],"t":["r","y","f","g"],"y":["t","u","g","h"],
    "u":["y","i","h","j"],"i":["u","o","j","k"],"o":["i","p","k","l"],
    "p":["o","l"],"a":["q","w","s","z"],"s":["a","w","e","d","z","x"],
    "d":["s","e","r","f","x","c"],"f":["d","r","t","g","c","v"],
    "g":["f","t","y","h","v","b"],"h":["g","y","u","j","b","n"],
    "j":["h","u","i","k","n","m"],"k":["j","i","o","l","m"],
    "l":["k","o","p"],"z":["a","s","x"],"x":["z","s","d","c"],
    "c":["x","d","f","v"],"v":["c","f","g","b"],"b":["v","g","h","n"],
    "n":["b","h","j","m"],"m":["n","j","k"]
]

private let RISKY_CORRECTIONS: Set<String> = [
    "hell","damn","shit","fuck","bitch","ass","crap","piss","dick",
    "cock","pussy","tits","boobs","sex","porn","nude","naked","kill",
    "die","dead","murder","suicide","drug","drugs","weed","cocaine",
    "heroin","meth","alcohol","drunk","beer","wine","vodka","whiskey",
    // extra guard rails for common misflips
    "suck","duck","fucking","tit","cunt"
]

private let SEED_COLLOQUIALS: [String] = [
    "lol","omg","wtf","btw","fyi","imo","imho","brb","ttyl","rofl",
    "lmao","smh","tbh","irl","afaik","tl;dr","aka","fomo","yolo",
    "bae","squad","lit","salty","shade","tea","stan","periodt",
    "cap","no cap","bet","vibe","mood","lowkey","highkey","deadass",
    "fr","ngl","slaps","hits different","main character",
    "pov","bestie","sis","king","queen","icon","legend"
]

// Pre-compiled regex patterns (singletons)
private let SENTENCE_END_REGEX = try! NSRegularExpression(pattern: "([.!?])\\s+([a-z])")
private let PUNCT_SPACE_REGEX   = try! NSRegularExpression(pattern: "\\s+([.,!?;:])")
private let DOUBLE_SPACE_REGEX  = try! NSRegularExpression(pattern: "\\s{2,}")
private let LINK_DETECTOR: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

// MARK: - String Extensions
extension String {
    var normalizedForSpell: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{00AD}", with: "")   // soft hyphen
            .replacingOccurrences(of: "\u{200B}", with: "")   // zero-width space
            .replacingOccurrences(of: "\u{200C}", with: "")   // ZWNJ
            .replacingOccurrences(of: "\u{200D}", with: "")   // ZWJ
    }

    private static let _symbolChars = CharacterSet.symbols.union(.punctuationCharacters)

    var isEmojiOrSymbol: Bool {
        for scalar in unicodeScalars {
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji { return true }
        }
        return rangeOfCharacter(from: Self._symbolChars) != nil && rangeOfCharacter(from: .letters) == nil
    }

    // OPTIMIZED: reuse singleton link detector
    var isURL: Bool {
        guard let detector = LINK_DETECTOR else { return false }
        let ns = self as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard let m = detector.matches(in: self, options: [], range: r).first else { return false }
        return m.range.location == 0 && m.range.length == ns.length
    }

    var isMentionOrHashtag: Bool { hasPrefix("@") || hasPrefix("#") }
}

// MARK: - Personal Dictionary
final class UserLexicon {
    static let shared = UserLexicon()
    private let keyLearn = "lex_learned"
    private let keyIgnore = "lex_ignored"
    private let ud = AppGroups.shared

    private(set) var learned: Set<String> = []
    private(set) var ignored: Set<String> = []

    private init() {
        learned = Set(ud.stringArray(forKey: keyLearn) ?? [])
        ignored = Set(ud.stringArray(forKey: keyIgnore) ?? [])
    }

    func learn(_ w: String) {
        learned.insert(w.lowercased())
        ud.set(Array(learned), forKey: keyLearn)
    }
    func ignore(_ w: String) {
        ignored.insert(w.lowercased())
        ud.set(Array(ignored), forKey: keyIgnore)
    }
    func isUserKnown(_ w: String) -> Bool {
        learned.contains(w.lowercased()) || ignored.contains(w.lowercased())
    }
    func removeFromLearned(_ w: String) {
        learned.remove(w.lowercased())
        ud.set(Array(learned), forKey: keyLearn)
    }
    func removeFromIgnored(_ w: String) {
        ignored.remove(w.lowercased())
        ud.set(Array(ignored), forKey: keyIgnore)
    }

    func getLearnedWords() -> [String] { Array(learned).sorted() }
    func getIgnoredWords() -> [String] { Array(ignored).sorted() }
}

// MARK: - Context-Aware Bigram Scorer (tiny static table)
final class BigramScorer {
    private let freq: [String: Int]
    private static let defaultTable: [String: Int] = [
        "to be": 50, "of the": 45, "in the": 40, "and the": 35,
        "a lot": 30, "you are": 25, "it is": 25, "that is": 20, "this is": 20,
        "would have": 15, "could have": 15, "should have": 15, "going to": 15,
        "want to": 12, "have to": 12, "used to": 10, "how to": 10,
        "there are": 8, "there is": 8, "they are": 8, "we are": 8,
        "won't be": 5, "can't be": 5, "don't have": 5, "doesn't have": 5
    ]
    init(freq: [String: Int] = [:]) { self.freq = freq.isEmpty ? Self.defaultTable : freq }

    @inline(__always)
    func score(prev: String?, cand: String, next: String?) -> Int {
        var s = 0
        if let p = prev { s += freq["\(p.lowercased()) \(cand.lowercased())"] ?? 0 }
        if let n = next { s += freq["\(cand.lowercased()) \(n.lowercased())"] ?? 0 }
        return s
    }
}

// MARK: - Spell Work Queue (Non-blocking, coalesced)
final class SpellWorkQueue {
    static let shared = SpellWorkQueue()
    private let queue = DispatchQueue(label: "spell.queue", qos: .userInitiated)
    private var pendingToken: UUID?
    private init() {}

    func coalesced<T>(_ work: @escaping () -> T, deliver: @escaping (T) -> Void) {
        let token = UUID()
        pendingToken = token
        queue.async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard self?.pendingToken == token else { return }
                deliver(result)
            }
        }
    }
}

/// Enhanced spell checker for keyboard extension with advanced features
/// Lightweight by design: file-scoped singletons, bounded caches, small tables only.
final class LightweightSpellChecker {

    // MARK: - Singleton
    static let shared = LightweightSpellChecker()

    // MARK: - Core Components
    #if canImport(UIKit)
    private let textChecker = UITextChecker()
    #endif
    private let userLex = UserLexicon.shared
    private let bgScorer = BigramScorer()
    private let workQueue = SpellWorkQueue.shared
    private let languageRecognizer = NLLanguageRecognizer()

    // MARK: - State / Config
    private var domainMode: DomainMode = .general
    private var languageCache: [String: String] = [:]
    private var lastUndoableCorrection: (original: String, replacement: String, range: NSRange)?

    // Language detection pacing
    private var langDetectAnchorCount = 0
    private let langDetectStep = 40
    private var lastDetectedLang: String?

    // PERSISTENCE: Acceptance learning
    private let acceptanceCountsKey = "spell_acceptance_counts"
    private var acceptanceCounts: [String: Int] = [:]
    private let acceptanceBoostThreshold = 3

    // Buffered writes
    private var persistenceBuffer: [String: Any] = [:]
    private var persistenceTimer: Timer?
    private let persistenceFlushDelay: TimeInterval = 2.0

    // Allow-list cache
    private var cachedAllowList: Set<String> = []
    private var allowCacheTimestamp: TimeInterval = 0

    // Behavior flags
    var autoInsertTerminalPeriod = false
    var autoCapitalizeAfterPunctuation = true
    var autoSwitchToABCAfterPunctuation = true

    private var traitsWantsAutocorrect = true
    private var smartQuotesEnabled = true
    private var touchLikelihoods: [Character: Double] = [:]

    enum DomainMode {
        case general, email, url, numeric
        var shouldSkipSpellCheck: Bool {
            switch self {
            case .email, .url, .numeric: return true
            case .general: return false
            }
        }
    }

    struct SpellSuggestion {
        let word: String
        let confidence: Float
        let isFromUserDict: Bool
        let editDistance: UInt8
        let contextScore: Int16
        var totalScore: Float {
            let base = confidence * 100
            let distPenalty = Float(editDistance) * -10
            let ctxBonus = Float(contextScore) * 5
            return base + distPenalty + ctxBonus + (isFromUserDict ? 50 : 0)
        }
    }

    private init() {
        let ud = AppGroups.shared
        if let saved = ud.dictionary(forKey: acceptanceCountsKey) as? [String: Int] {
            acceptanceCounts = saved
        }
    }

    // MARK: - Language prefs
    private var preferredLanguage: String = "en_US"

    private func resolvedLanguage(_ override: String? = nil) -> String {
        #if canImport(UIKit)
        let langs = UITextChecker.availableLanguages
        let candidate = (override ?? preferredLanguage)
        if langs.contains(candidate) { return candidate }
        let prefix2 = String(candidate.prefix(2))
        if let match = langs.first(where: { $0.hasPrefix(prefix2) }) { return match }
        if let en = langs.first(where: { $0.hasPrefix("en") }) { return en }
        return langs.first ?? "en_US"
        #else
        return override ?? preferredLanguage
        #endif
    }

    func setPreferredLanguage(_ bcp47: String?) {
        guard let b = bcp47, !b.isEmpty else { return }
        let normalized = b.replacingOccurrences(of: "-", with: "_")
        #if canImport(UIKit)
        let langs = UITextChecker.availableLanguages
        if langs.contains(normalized) { preferredLanguage = normalized; return }
        let prefix2 = String(normalized.prefix(2))
        if let match = langs.first(where: { $0.hasPrefix(prefix2) }) { preferredLanguage = match; return }
        #endif
        preferredLanguage = normalized
    }

    // CONTEXT-AWARE: Set document language from textDocumentProxy
    func setDocumentPrimaryLanguage(_ bcp47: String?) { setPreferredLanguage(bcp47) }

    // MARK: - Allow-list (CACHED)
    private func allowedWords() -> Set<String> {
        let ud = AppGroups.shared
        let ts = ud.double(forKey: "profanity_allowlist_ts")
        if ts == allowCacheTimestamp && !cachedAllowList.isEmpty { return cachedAllowList }
        let defaults = (ud.array(forKey: "profanity_allowlist") as? [String]) ?? []
        cachedAllowList = Set(defaults.map { $0.lowercased() } + SEED_COLLOQUIALS)
        allowCacheTimestamp = ts
        return cachedAllowList
    }

    // MARK: - Autocorrect safety rails
    private let riskyCorrections: Set<String> = RISKY_CORRECTIONS

    // MARK: - Multi-word corrections (commit boundary only)
    private let multiWordPatterns: [String: String] = [
        "alot":"a lot","incase":"in case","infact":"in fact","aswell":"as well",
        "eachother":"each other","thankyou":"thank you","atleast":"at least",
        "everyday":"every day","anymore":"any more","anytime":"any time",
        "onto":"on to","into":"in to","somtimes":"sometimes","ofcourse":"of course",
        "nevermind":"never mind","inspite":"in spite","uptil":"up till","upto":"up to","aslong":"as long"
    ]

    // MARK: - Suggestion cache (tiny, bounded)
    private var suggestionCache: [String: (t: CFAbsoluteTime, vals: [String])] = [:]
    private let suggestionCacheLimit = 256
    private let suggestionCacheTTL: CFTimeInterval = 120 // seconds

    private func cacheSuggestions(for key: String, _ vals: [String]) {
        suggestionCache[key] = (CFAbsoluteTimeGetCurrent(), vals)
        if suggestionCache.count > suggestionCacheLimit {
            // prune oldest ~25%
            let sorted = suggestionCache.sorted { $0.value.t < $1.value.t }
            for (k, _) in sorted.prefix(suggestionCacheLimit / 4) { suggestionCache.removeValue(forKey: k) }
        }
    }

    private func cachedSuggestions(for key: String) -> [String]? {
        guard let entry = suggestionCache[key] else { return nil }
        if CFAbsoluteTimeGetCurrent() - entry.t > suggestionCacheTTL { suggestionCache.removeValue(forKey: key); return nil }
        return entry.vals
    }

    // MARK: - Gates / decisions
    private func isWordBoundary(_ c: Character) -> Bool { c == " " || c == "\n" || c == "." || c == "!" || c == "?" }

    private func drasticallyChangesPhonetics(_ a: String, _ b: String) -> Bool {
        func skeleton(_ s: String) -> String {
            let vowels = Set("aeiou")
            return s.lowercased().filter { ("a"..."z").contains($0) }.map { vowels.contains($0) ? "v" : "c" }.joined()
        }
        return editDistance(skeleton(a), skeleton(b)) > 1
    }

    private func isLikelyTapSlip(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count, a.count >= 1 else { return false }
        let aChars = Array(a.lowercased()), bChars = Array(b.lowercased())
        var diffs = 0
        var from: Character = "\0", to: Character = "\0"
        for i in 0..<aChars.count where aChars[i] != bChars[i] {
            diffs += 1; from = aChars[i]; to = bChars[i]; if diffs > 1 { return false }
        }
        guard diffs == 1 else { return false }
        return QWERTY_NEIGHBORS[from]?.contains(to) == true
    }

    private func shouldApplyCorrection(original: String, suggestion: String) -> Bool {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if o == s { return false }
        if s.contains("-") { return false }
        if o.contains(" ") || s.contains(" ") { return false }

        // Only allow single edit distance for auto
        let d = editDistance(o.lowercased(), s.lowercased())
        if d != 1 { return false }

        if isLikelyTapSlip(o, s) { return true }
        if drasticallyChangesPhonetics(o, s) && d > 1 { return false }

        // Acronyms / Proper nouns
        if o.count >= 4 && o == o.uppercased() { return false }
        if o.count >= 3 && o.first?.isUppercase == true && !(s.first?.isUppercase ?? false) { return false }
        return true
    }

    private func matchCasing(of original: String, to suggestion: String) -> String {
        if original == original.uppercased() { return suggestion.uppercased() }
        if original.prefix(1) == original.prefix(1).uppercased(),
           original.dropFirst() == original.dropFirst().lowercased() {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst().lowercased()
        }
        return suggestion
    }

    private func isSafeSuggestion(original: String, suggestion: String) -> Bool {
        let o = original.lowercased(), s = suggestion.lowercased()
        if s.contains("-") { return false }
        if riskyCorrections.contains(o) || riskyCorrections.contains(s) { return false }
        return shouldApplyCorrection(original: o, suggestion: s)
    }

    // MARK: - Edit distance (2-row Levenshtein)
    @inline(__always)
    private func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        let (s, t) = aChars.count <= bChars.count ? (aChars, bChars) : (bChars, aChars)
        var prev = Array(0...s.count)
        var curr = Array(repeating: 0, count: s.count + 1)
        for (i, tb) in t.enumerated() {
            curr[0] = i + 1
            for j in 0..<s.count {
                let cost = (s[j] == tb) ? 0 : 1
                curr[j+1] = min(prev[j+1] + 1, curr[j] + 1, prev[j] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[s.count]
    }

    // MARK: - Local corrections (UITextChecker + fast table) with cache
    private func localCorrections(for word: String, language: String? = nil) -> [String] {
        #if canImport(UIKit)
        guard !word.isEmpty else { return [] }

        // Allow-list bypass (colloquials etc.)
        if allowedWords().contains(word.lowercased()) { return [] }

        // Fast typo first
        let lower = word.lowercased()
        if let fast = FAST_TYPOS[lower] {
            let cased = matchCasing(of: word, to: fast)
            if isSafeSuggestion(original: word, suggestion: cased) { return [cased] }
        }

        // Cache
        if let cached = cachedSuggestions(for: lower) { return cached }

        let lang = resolvedLanguage(language)
        let nsWord = word as NSString
        let range = NSRange(location: 0, length: nsWord.length)

        let miss = textChecker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: lang)
        guard miss.location != NSNotFound else { cacheSuggestions(for: lower, []); return [] }

        let guesses = textChecker.guesses(forWordRange: miss, in: word, language: lang) ?? []
        let filtered = guesses
            .map { matchCasing(of: word, to: $0) }
            .filter { isSafeSuggestion(original: word, suggestion: $0) }
        let top = Array(filtered.prefix(3))
        cacheSuggestions(for: lower, top)
        return top
        #else
        return []
        #endif
    }

    func isWordCorrect(_ word: String, language: String? = nil) -> Bool {
        #if canImport(UIKit)
        guard !word.isEmpty else { return true }
        if allowedWords().contains(word.lowercased()) { return true }
        let lang = resolvedLanguage(language)
        let nsWord = word as NSString
        let range = NSRange(location: 0, length: nsWord.length)
        let miss = textChecker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: lang)
        return miss.location == NSNotFound
        #else
        return true
        #endif
    }

    // MARK: - Async quick check (coalesced)
    func quickSpellCheckAsync(text: String, completion: @escaping ([String]) -> Void) {
        guard text.count >= 2, text.count <= 2000 else { completion([]); return }
        workQueue.coalesced({
            let last = self.lastWord(in: text)
            guard let currentWord = last,
                  currentWord.count >= 2, currentWord.count <= 24,
                  currentWord.rangeOfCharacter(from: .letters) != nil else { return [] }
            return self.localCorrections(for: currentWord)
        }, deliver: completion)
    }

    func getAutoCorrection(for word: String) -> String? {
        guard word.count >= 2, word.count <= 24 else { return nil }
        return localCorrections(for: word).first
    }

    // PATCH #1: allow short common fixes (e.g., Yoi → You)
    func shouldAutoCorrect(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        let w = word
        if w == w.uppercased() { return false }
        if w.prefix(1) == w.prefix(1).uppercased(), w.dropFirst() == w.dropFirst().lowercased() {
            if FAST_TYPOS[w.lowercased()] == nil { return false }
        }
        if allowedWords().contains(word.lowercased()) { return false }
        if isIntentionallyTyped(word) { return false }
        guard !isWordCorrect(word) else { return false }
        let corrections = localCorrections(for: word)
        guard let first = corrections.first else { return false }

        // Acceptance learning fast path
        let key = "\(word.lowercased())->\(first.lowercased())"
        if acceptanceCounts[key, default: 0] >= acceptanceBoostThreshold { return true }

        let editDist = editDistance(word.lowercased(), first.lowercased())
        let isCommonTypo = FAST_TYPOS[word.lowercased()] != nil
        return editDist == 1 && isCommonTypo
    }

    func requestSuggestions(for text: String, range: NSRange, completion: @escaping ([String]?) -> Void) {
        guard range.length >= 2, range.length <= 24 else { completion(nil); return }
        let ns = text as NSString
        guard range.location + range.length <= ns.length else { completion(nil); return }
        let sub = ns.substring(with: range)
        let suggestions = localCorrections(for: sub)
        completion(suggestions.isEmpty ? nil : suggestions)
    }

    func quickSpellCheck(text: String) -> [String] { [] }

    // MARK: - Inline correction state
    private var lastCorrectedWord: String?
    private var lastOriginalWord: String?

    func applyInlineCorrection(_ suggestion: String, originalWord: String) {
        lastCorrectedWord = suggestion
        lastOriginalWord = originalWord
    }
    func canUndoLastCorrection() -> Bool { lastCorrectedWord != nil && lastOriginalWord != nil }
    func getUndoCorrection() -> (original: String, corrected: String)? {
        guard let corrected = lastCorrectedWord, let original = lastOriginalWord else { return nil }
        return (original, corrected)
    }
    func clearUndoState() { lastCorrectedWord = nil; lastOriginalWord = nil }

    // MARK: - Intentional typing tracking
    private struct IntentionalEntry { var count: Int; var lastSeen: CFTimeInterval }
    private var intentionalWords: [String: IntentionalEntry] = [:]
    private let intentionalTTL: CFTimeInterval = 10 * 60 // 10 min

    private func isIntentionallyTyped(_ word: String) -> Bool {
        let key = word.lowercased()
        guard let e = intentionalWords[key] else { return false }
        if CFAbsoluteTimeGetCurrent() - e.lastSeen > intentionalTTL {
            intentionalWords.removeValue(forKey: key)
            return false
        }
        return e.count >= 1
    }
    private func markAutocorrected(_ word: String) { /* no-op by design */ }
    private func markIntentional(_ word: String) {
        intentionalWords[word.lowercased()] = IntentionalEntry(count: 1, lastSeen: CFAbsoluteTimeGetCurrent())
    }

    // MARK: - Capitalization / punctuation
    private let sentenceEnders: CharacterSet = CharacterSet(charactersIn: ".!?")
    private let commonAbbreviations = Set(["dr","mr","mrs","ms","prof","inc","ltd","corp","etc","vs","st","ave","blvd","dept","govt","assn"])
    private let alwaysCapitalize = Set(["i","i'm","i'll","i've","i'd"])

    func applyCaptializationRules(to text: String) -> String { applyCapitalizationRules(to: text) }

    private func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private func capitalizeAfterSentenceEndings(_ text: String) -> String {
        var result = text
        let ns = result as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = SENTENCE_END_REGEX.matches(in: result, options: [], range: fullRange)
        for match in matches.reversed() {
            let enderRange = match.range(at: 1)
            if let swiftEnder = Range(enderRange, in: result) {
                let beforePeriod = String(result[..<swiftEnder.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let lastWord = beforePeriod.components(separatedBy: .whitespacesAndNewlines).last?.lowercased(),
                   commonAbbreviations.contains(lastWord) { continue }
            }
            let letterRange = match.range(at: 2)
            let nsNow = result as NSString
            let letter = nsNow.substring(with: letterRange).uppercased()
            result = nsNow.replacingCharacters(in: letterRange, with: letter)
        }
        return result
    }

    private func capitalizeCommonProperNouns(_ text: String) -> String {
        let weekdays = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]
        let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
        let languages = ["english","spanish","french","german","chinese","japanese","italian","portuguese","russian","arabic"]
        let countries = ["america","american","usa","canada","canadian","mexico","mexican","england","british","france","french","germany","german","china","chinese","japan","japanese"]
        let nouns = weekdays + months + languages + countries

        var result = text
        let ns = result as NSString
        for noun in nouns {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: noun))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: ns.length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: noun.capitalized)
            }
        }
        return result
    }

    private func applyCapitalizationRules(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = capitalizeFirstLetter(result)
        result = capitalizeAfterSentenceEndings(result)
        result = capitalizeCommonProperNouns(result)

        for phrase in alwaysCapitalize {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: phrase.capitalized)
            }
        }
        if result.hasPrefix("i ") || result.hasPrefix("i'") {
            result = "I" + result.dropFirst()
        }
        return result
    }

    func applyPunctuationRules(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = addSpaceAfterPunctuation(result)
        result = removeSpaceBeforePunctuation(result)
        result = fixCommonContractions(result)
        result = addPeriodIfNeeded(result)
        result = fixCommonGrammarMistakes(result)
        result = condenseSpaces(result)
        return result
    }

    func getCapitalizationAndPunctuationSuggestions(for text: String) -> [String] {
        guard text.count > 5 else { return [] }
        var suggestions: [String] = []
        let cap = applyCaptializationRules(to: text)
        if cap != text { suggestions.append(cap) }
        let punct = applyPunctuationRules(to: text)
        if punct != text { suggestions.append(punct) }
        let both = applyPunctuationRules(to: cap)
        if both != text && both != cap && both != punct { suggestions.append(both) }
        return Array(suggestions.prefix(3))
    }

    func getRealTimeGrammarSuggestions(for text: String, cursorPosition: Int = -1) -> [String] {
        guard !text.isEmpty else { return [] }
        let pos = cursorPosition >= 0 ? cursorPosition : text.count
        let working = String(text.prefix(pos))
        var out: [String] = []

        let words = working.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 2 {
            let lastTwo = words.suffix(2).joined(separator: " ")
            let fixed = fixCommonGrammarMistakes(lastTwo)
            if fixed != lastTwo { out.append(fixed) }
        }

        if let last = working.unicodeScalars.last, sentenceEnders.contains(last) {
            out.append("Capitalize next word")
        }

        if let lastWord = words.last?.lowercased() {
            switch lastWord {
            case "wont": out.append("won't")
            case "cant": out.append("can't")
            case "dont": out.append("don't")
            case "im": out.append("I'm")
            case "youre": out.append("you're")
            case "theyre": out.append("they're")
            case "ive": out.append("I've")
            case "id": out.append("I'd")
            case "youve": out.append("you've")
            case "youd": out.append("you'd")
            case "weve": out.append("we've")
            case "wed": out.append("we'd")
            case "were": out.append("we're")
            case "theyve": out.append("they've")
            case "theyd": out.append("they'd")
            case "theres": out.append("there's")
            case "thered": out.append("there'd")
            case "thatll": out.append("that'll")
            case "thats": out.append("that's")
            case "whos": out.append("who's")
            case "whod": out.append("who'd")
            case "wholl": out.append("who'll")
            case "whove": out.append("who've")
            case "whats": out.append("what's")
            case "whatre": out.append("what're")
            case "whatll": out.append("what'll")
            case "where's": out.append("where's")
            case "whereve": out.append("where've")
            case "how's": out.append("how's")
            case "howve": out.append("how've")
            case "isnt": out.append("isn't")
            case "arent": out.append("aren't")
            case "wasnt": out.append("wasn't")
            case "werent": out.append("weren't")
            case "hasnt": out.append("hasn't")
            case "havent": out.append("haven't")
            case "hadnt": out.append("hadn't")
            case "shouldnt": out.append("shouldn't")
            case "wouldnt": out.append("wouldn't")
            case "couldnt": out.append("couldn't")
            case "mustnt": out.append("mustn't")
            case "mightnt": out.append("mightn't")
            case "daren't": out.append("daren't")
            default: break
            }
        }
        return Array(out.prefix(2))
    }

    private func addSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        for p in [".", ",", "!", "?", ":", ";"] {
            let pattern = "\\\(p)([A-Za-z])"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\(p) $1")
            }
        }
        return result
    }

    private func removeSpaceBeforePunctuation(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return PUNCT_SPACE_REGEX.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: "$1")
    }

    private func fixCommonContractions(_ text: String) -> String {
        if text.isURL || text.isMentionOrHashtag || text == text.uppercased() { return text }
        let map: [String:String] = [
            "wont":"won't","cant":"can't","dont":"don't","isnt":"isn't","wasnt":"wasn't",
            /* "were":"we're" (ambiguous—skip) */
            "hasnt":"hasn't","havent":"haven't","shouldnt":"shouldn't","couldnt":"couldn't","wouldnt":"wouldn't",
            "thats":"that's","whats":"what's","hes":"he's","shes":"she's","its":"it's",
            "im":"I'm","youre":"you're","theyre":"they're",
            "ill":"I'll","ive":"I've","id":"I'd",
            "lets":"let's","itll":"it'll","weve":"we've"
        ]
        var result = text
        for (wrong, correct) in map {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length))
            guard !matches.isEmpty else { continue }
            for m in matches.reversed() {
                let matched = (result as NSString).substring(with: m.range)
                let cased = preserveCase(template: correct, like: matched)
                result = (result as NSString).replacingCharacters(in: m.range, with: cased)
            }
        }
        result = result
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "''", with: "\"")
            .replacingOccurrences(of: "`", with: "\"")
        return result
    }

    private func addPeriodIfNeeded(_ text: String) -> String {
        guard autoInsertTerminalPeriod else { return text }
        guard text.count > 10 else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, [".","!","?",";", ":"].contains(String(last)) { return text }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 3 { return trimmed + "." }
        return text
    }

    private func fixCommonGrammarMistakes(_ text: String) -> String {
        var result = text
        let fixes: [(String,String)] = [
            ("\\btheir\\b(?=\\s+(is|are|was|were))","there"),
            ("\\bthere\\b(?=\\s+(car|house|phone|computer))","their"),
            ("\\byour\\b(?=\\s+(welcome|right))","you're"),
            ("\\byoure\\b","you're"),
            ("\\bto\\b(?=\\s+(much|many))","too"),
            ("\\btoo\\b(?=\\s+(go|be|see|do))","to"),
            ("\\bwould\\s+of\\b","would have"),
            ("\\bcould\\s+of\\b","could have"),
            ("\\bshould\\s+of\\b","should have"),
            ("\\balot\\b","a lot"),
            ("\\bwanna\\b","want to"),
            ("\\bgonna\\b","going to")
        ]
        for (pattern, replacement) in fixes {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        return result
    }

    private func condenseSpaces(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return DOUBLE_SPACE_REGEX.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: " ")
    }

    // MARK: - Language & domain
    func detectLanguage(for text: String) -> String? {
        if lastDetectedLang == nil || text.count >= langDetectAnchorCount + langDetectStep {
            langDetectAnchorCount = text.count
            let windowed = String(text.prefix(200))
            if let cached = languageCache[windowed] {
                lastDetectedLang = cached
                return cached
            }
            languageRecognizer.reset()
            languageRecognizer.processString(windowed)
            if let lang = languageRecognizer.dominantLanguage?.rawValue {
                let resolved = lang.replacingOccurrences(of: "-", with: "_")
                languageCache[windowed] = resolved
                lastDetectedLang = resolved
                return resolved
            }
        }
        return lastDetectedLang
    }

    func detectDomainMode(for text: String) -> DomainMode {
        let lower = text.lowercased()
        if lower.contains("@") && lower.contains(".") { return .email }
        if lower.hasPrefix("http") || lower.contains("www.") { return .url }
        if text.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil { return .numeric }
        return .general
    }

    // MARK: - Smart tokenization (lightweight)
    func smartTokenize(_ text: String) -> [(word: String, range: NSRange)] {
        var tokens: [(String, NSRange)] = []
        let nsText = text as NSString
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .tokenType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let nsRange = NSRange(range, in: text)
            let word = nsText.substring(with: nsRange)
            if let tag = tag {
                switch tag {
                case .other, .otherWord:
                    if !word.isEmojiOrSymbol && !word.isURL && !word.isMentionOrHashtag {
                        tokens.append((word, nsRange))
                    }
                case .word:
                    tokens.append((word, nsRange))
                default: break
                }
            } else if word.rangeOfCharacter(from: .letters) != nil {
                tokens.append((word, nsRange))
            }
            return true
        }
        return tokens
    }

    // MARK: - Enhanced Spell Checking (sync path used by decide())
    func enhancedSpellCheck(text: String,
                            previousWord: String? = nil,
                            nextWord: String? = nil,
                            completion: @escaping ([SpellSuggestion]) -> Void) {
        workQueue.coalesced({
            self.performEnhancedSpellCheck(text: text, previousWord: previousWord, nextWord: nextWord)
        }, deliver: completion)
    }

    private func performEnhancedSpellCheck(text: String,
                                           previousWord: String?,
                                           nextWord: String?) -> [SpellSuggestion] {
        let normalized = text.normalizedForSpell
        let detectedMode = detectDomainMode(for: text)
        if detectedMode.shouldSkipSpellCheck { return [] }
        if userLex.isUserKnown(normalized) { return [] }
        let language = detectLanguage(for: text) ?? preferredLanguage
        #if canImport(UIKit)
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let misspelledRange = textChecker.rangeOfMisspelledWord(in: text, range: range, startingAt: 0, wrap: false, language: language)
        guard misspelledRange.location != NSNotFound else { return [] }
        let suggestions = textChecker.guesses(forWordRange: misspelledRange, in: text, language: language) ?? []

        var enhanced: [SpellSuggestion] = []
        for suggestion in suggestions {
            let editDist = editDistance(text, suggestion)
            let contextScore = bgScorer.score(prev: previousWord, cand: suggestion, next: nextWord)
            let isUserWord = userLex.learned.contains(suggestion.lowercased())
            let prox = proximityBoost(original: text, suggestion: suggestion)
            let adjustedConfidence = Float(0.8 + prox * 0.15)
            enhanced.append(SpellSuggestion(word: suggestion,
                                            confidence: adjustedConfidence,
                                            isFromUserDict: isUserWord,
                                            editDistance: UInt8(min(editDist, 255)),
                                            contextScore: Int16(min(contextScore, Int(Int16.max)))))
        }
        for learnedWord in userLex.learned {
            let editDist = editDistance(text.lowercased(), learnedWord)
            if editDist <= 2 && !suggestions.contains(learnedWord) {
                let contextScore = bgScorer.score(prev: previousWord, cand: learnedWord, next: nextWord)
                enhanced.append(SpellSuggestion(word: learnedWord,
                                                confidence: 0.9,
                                                isFromUserDict: true,
                                                editDistance: UInt8(min(editDist, 255)),
                                                contextScore: Int16(min(contextScore, Int(Int16.max)))))
            }
        }
        return enhanced.sorted { $0.totalScore > $1.totalScore }.prefix(5).map { $0 }
        #else
        return []
        #endif
    }

    // MARK: - Multi-word corrections
    func checkMultiWordCorrection(_ text: String, prev: String? = nil, next: String? = nil) -> (original: String, correction: String)? {
        let normalized = text.normalizedForSpell.lowercased()
        if let corr = multiWordPatterns[normalized] {
            if normalized == "into", let n = next, ["it","them","this","that"].contains(n.lowercased()) {
                return (text, "in to")
            }
            if normalized == "onto", let n = next, ["it","them","this","that"].contains(n.lowercased()) {
                return (text, "on to")
            }
            return (text, corr)
        }
        return nil
    }

    // MARK: - Personal Dictionary Management
    func learnWord(_ word: String) { userLex.learn(word) }
    func ignoreWord(_ word: String) { userLex.ignore(word) }
    func forgetWord(_ word: String) { userLex.removeFromLearned(word); userLex.removeFromIgnored(word) }
    func getPersonalDictionary() -> (learned: [String], ignored: [String]) { (userLex.getLearnedWords(), userLex.getIgnoredWords()) }
    func actionsForWord(_ word: String) -> [(title: String, handler: () -> Void)] {
        var items: [(String, () -> Void)] = []
        if !userLex.isUserKnown(word) {
            items.append(("Learn \"\(word)\"", { self.learnWord(word) }))
            items.append(("Ignore \"\(word)\"", { self.ignoreWord(word) }))
        } else {
            items.append(("Forget \"\(word)\"", { self.forgetWord(word) }))
        }
        return items
    }

    // MARK: - Undo
    func recordCorrection(original: String, replacement: String, range: NSRange) {
        lastUndoableCorrection = (original, replacement, range)
    }
    func getLastCorrection() -> (original: String, replacement: String, range: NSRange)? { lastUndoableCorrection }
    func clearUndoHistory() { lastUndoableCorrection = nil }

    // MARK: - Acceptance Learning
    func recordAcceptedCorrection(original: String, corrected: String) {
        let key = "\(original.lowercased())->\(corrected.lowercased())"
        acceptanceCounts[key, default: 0] += 1
        scheduleBufferedPersistence()
    }

    private func scheduleBufferedPersistence() {
        persistenceBuffer[acceptanceCountsKey] = acceptanceCounts
        persistenceTimer?.invalidate()
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: persistenceFlushDelay, repeats: false) { [weak self] _ in
            self?.flushPersistenceBuffer()
        }
    }

    private func flushPersistenceBuffer() {
        guard !persistenceBuffer.isEmpty else { return }
        let ud = AppGroups.shared
        for (key, value) in persistenceBuffer { ud.set(value, forKey: key) }
        persistenceBuffer.removeAll()
        persistenceTimer?.invalidate()
        persistenceTimer = nil
    }

    // MARK: - ONE-SHOT DECISION
    struct Decision {
        let replacement: String?
        let suggestions: [String]
        let applyAuto: Bool
    }

    func decide(for currentWord: String,
                prev: String? = nil,
                next: String? = nil,
                langOverride: String? = nil,
                isOnCommitBoundary: Bool = false) -> Decision {
        guard traitsWantsAutocorrect else { return Decision(replacement: nil, suggestions: [], applyAuto: false) }
        setDocumentPrimaryLanguage(langOverride)

        if isWordKnownByUser(currentWord) || allowedWords().contains(currentWord.lowercased()) {
            return Decision(replacement: nil, suggestions: [], applyAuto: false)
        }

        if isOnCommitBoundary, let multi = checkMultiWordCorrection(currentWord, prev: prev, next: next) {
            return Decision(replacement: multi.correction, suggestions: [multi.correction], applyAuto: true)
        }

        let autoOkay = isOnCommitBoundary ? shouldAutoCorrect(currentWord) : false
        if autoOkay, let auto = getAutoCorrection(for: currentWord) {
            return Decision(replacement: auto, suggestions: [auto], applyAuto: true)
        }

        let enhanced = performEnhancedSpellCheck(text: currentWord, previousWord: prev, nextWord: next)
        return Decision(replacement: nil, suggestions: enhanced.map { $0.word }, applyAuto: false)
    }

    // MARK: - Utilities
    private func lastWord(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: .whitespacesAndNewlines)
        guard let raw = parts.last, !raw.isEmpty else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()[]{}\"'"))
    }

    #if canImport(UIKit)
    private func handlePunctuation(_ punctuation: String, with textProxy: UITextDocumentProxy) {
        textProxy.insertText(punctuation)
        if [".","!","?"].contains(punctuation) { textProxy.insertText(" ") }
        // switchToAlphabeticKeyboard() // if you wire this in your controller
    }
    #endif

    private func switchToAlphabeticKeyboard() { /* template hook for controller */ }

    // MARK: - Status
    func getAPIStatus() -> [String: Any] {
        [
            "spell_checker": "UITextChecker_only",
            "local_checker_available": canUseLocalChecker(),
            "preferred_language": preferredLanguage,
            "resolved_language": preferredLanguage,
            "can_undo_correction": canUndoLastCorrection(),
            "features": [
                "spelling","capitalization","punctuation","contractions",
                "smart_quotes","proper_nouns","grammar_fixes","abbreviation_awareness",
                "real_time_suggestions"
            ]
        ]
    }

    private func canUseLocalChecker() -> Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    func initializeForKeyboardExtension() { clearUndoState() }
    func cleanup() { clearUndoState() }

    // MARK: - Public Utilities
    static func lastToken(in text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
        let parts = cleaned.components(separatedBy: .whitespacesAndNewlines)
        guard let raw = parts.last, !raw.isEmpty else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()[]{}\"'"))
    }

    func isWordKnownByUser(_ word: String) -> Bool { userLex.isUserKnown(word) }
    func recordAutocorrection(_ word: String) { markAutocorrected(word) }
    func recordIntentionalWord(_ word: String) { markIntentional(word) }

    // MARK: - Auto-Cap & ABC recommendations
    func shouldCapitalizeNext(afterText text: String) -> Bool {
        guard autoCapitalizeAfterPunctuation else { return false }
        if text.isEmpty { return true }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let sentenceEndPattern = #"[.!?]['")\]]*\s*$"#
        if text.range(of: sentenceEndPattern, options: .regularExpression) != nil { return true }
        if text.hasSuffix("\n") || text.hasSuffix("\r\n") { return true }
        if text.hasSuffix(": ") { return true }
        return false
    }

    func shouldSwitchToABCMode(afterText text: String, lastCharacter: Character) -> Bool {
        guard autoSwitchToABCAfterPunctuation else { return false }
        if [".","!","?"].contains(String(lastCharacter)) { return true }
        if [",",";",":"].contains(String(lastCharacter)) && text.hasSuffix(" ") { return true }
        return false
    }

    func getRecommendedKeyboardState(forText text: String) -> (shouldCapitalize: Bool, shouldUseABCMode: Bool) {
        let shouldCap = shouldCapitalizeNext(afterText: text)
        let shouldABC = shouldCap || text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (shouldCap, shouldABC)
    }

    // MARK: - Apple-like integration
    #if canImport(UIKit)
    func syncFromTextTraits(_ proxy: UITextDocumentProxy) {
        if let cap = proxy.autocapitalizationType { autoCapitalizeAfterPunctuation = cap != .none }
        traitsWantsAutocorrect = proxy.autocorrectionType != .no
        smartQuotesEnabled = proxy.smartQuotesType != .no
        autoInsertTerminalPeriod = (proxy.smartInsertDeleteType ?? .default) != .no
        switch proxy.keyboardType {
        case .emailAddress: setDomainMode(.email)
        case .URL, .webSearch: setDomainMode(.url)
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation: setDomainMode(.numeric)
        default: setDomainMode(.general)
        }
    }

    private func setDomainMode(_ mode: DomainMode) { domainMode = mode }

    private func loadSystemLexicon(_ controller: UIInputViewController, completion: @escaping (Set<String>) -> Void) {
        controller.requestSupplementaryLexicon { lex in
            autoreleasepool {
                let set = Set(lex.entries.map { $0.userInput.lowercased() })
                completion(set)
            }
        }
    }

    private func loadContactsLexicon(completion: @escaping (Set<String>) -> Void) {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
        var out = Set<String>()
        let req = CNContactFetchRequest(keysToFetch: keys)
        do {
            try store.enumerateContacts(with: req) { c, _ in
                autoreleasepool {
                    [c.givenName, c.familyName, c.nickname]
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .forEach { out.insert($0.lowercased()) }
                }
            }
        } catch { /* ignore permission errors */ }
        completion(out)
    }

    func primeAppleLikeAllowList(using controller: UIInputViewController) {
        loadSystemLexicon(controller) { lex in
            self.loadContactsLexicon { contacts in
                autoreleasepool {
                    let merged = lex.union(contacts)
                    self.cachedAllowList = self.allowedWords().union(merged)
                    self.allowCacheTimestamp = Date().timeIntervalSince1970
                }
            }
        }
    }

    func reevaluatePreviousWord(before proxy: UITextDocumentProxy) -> AutoCorrectionCandidate? {
        guard let context = proxy.documentContextBeforeInput, !context.isEmpty else { return nil }
        let prev = LightweightSpellChecker.lastToken(in: context) ?? ""
        guard prev.count >= 2, !isWordKnownByUser(prev), !allowedWords().contains(prev.lowercased()) else { return nil }
        let nextStart = proxy.documentContextAfterInput ?? ""
        let next = LightweightSpellChecker.lastToken(in: nextStart)
        let decision = decide(for: prev, prev: nil, next: next, isOnCommitBoundary: true)
        guard decision.applyAuto, let replacement = decision.replacement, replacement != prev else { return nil }
        for _ in 0..<prev.count { proxy.deleteBackward() }
        proxy.insertText(replacement)
        return AutoCorrectionCandidate(original: prev, correction: replacement, confidence: 0.95, source: .local)
    }

    func learnWordSystemWide(_ w: String) { UITextChecker.learnWord(w); learnWord(w) }
    func unlearnWordSystemWide(_ w: String) { UITextChecker.unlearnWord(w); forgetWord(w) }

    func setTouchLikelihoods(_ map: [Character: Double]) { self.touchLikelihoods = map }

    private func proximityBoost(original: String, suggestion: String) -> Double {
        guard original.count == suggestion.count else { return 0 }
        let a = Array(original.lowercased())
        let b = Array(suggestion.lowercased())
        for i in 0..<a.count where a[i] != b[i] {
            return touchLikelihoods[b[i]] ?? 0
        }
        return 0
    }

    func handleDoubleSpace(_ proxy: UITextDocumentProxy) -> Bool {
        if let ctx = proxy.documentContextBeforeInput, ctx.hasSuffix("  ") {
            if traitsWantsAutocorrect && autoInsertTerminalPeriod {
                proxy.deleteBackward(); proxy.deleteBackward()
                proxy.insertText(". ")
                _ = reevaluatePreviousWord(before: proxy)
                return true
            }
        }
        return false
    }
    #else
    private func proximityBoost(original: String, suggestion: String) -> Double { 0 }
    private func setDomainMode(_ mode: DomainMode) { domainMode = mode }
    #endif
}

// MARK: - Apple-style data structures
struct SpellIssue {
    let word: String
    let range: NSRange
    let suggestions: [String]
    let isTypo: Bool
    init(word: String, range: NSRange, suggestions: [String], isTypo: Bool = true) {
        self.word = word; self.range = range; self.suggestions = suggestions; self.isTypo = isTypo
    }
}

struct AutoCorrectionCandidate {
    let original: String
    let correction: String
    let confidence: Double
    let source: CorrectionSource
    enum CorrectionSource { case local, remote, cached }
}

// Simple case mirror: ALLCAPS → ALLCAPS, Titlecase → Titlecase, else as-is
private func preserveCase(template: String, like sample: String) -> String {
    if sample == sample.uppercased() { return template.uppercased() }
    if sample == sample.capitalized {
        let first = template.prefix(1).uppercased()
        return first + template.dropFirst()
    }
    return template
}
