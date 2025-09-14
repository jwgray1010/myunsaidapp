// ToneAnalysisEngine.swift (lightweight, production-ready)
// Uses Aho–Corasick for literal multi-pattern scans (triggerwords, profanity, softeners)
// Keeps regex for complex patterns (tone_patterns, phrase_edges, intensity, negation, sarcasm)
// Integrates the JSON set you provided. Depends on SharedTypes.swift for enums/structs.
//
// Notes:
// - No duplication of shared types (ToneStatus, etc.) — those come from SharedTypes.swift as you said.
// - The engine is synchronous, allocation-light, and safe to call per keystroke (debounced by caller).
// - If a JSON field is missing, we safely degrade with defaults.
// - Public API: ToneAnalysisEngine.load(…), analyze(text: …) -> ToneClassification + audit
// - You can extend applyGuardrails in your Coordinator; this engine surfaces raw tone numbers + bands.

import Foundation

// MARK: - Minimal models (only the fields we read from your JSONs)

private struct TriggerwordsRoot: Decodable {
    struct Engine: Decodable { let caseInsensitive: Bool?; let normalize: [String]? }
    struct WeightsEntry: Decodable { let typeMultipliers: [String:Int]? }
    struct Group: Decodable { let text: String; let intensity: Int; let type: String; let variants: [String]? }
    struct Section: Decodable { let triggerwords: [Group]? }
    let engine: Engine?
    let weights: [String:WeightsEntry]?
    let alert: Section?
    let caution: Section?
    let clear: Section?
}

private struct ProfanityRoot: Decodable {
    struct Category: Decodable {
        let id: String
        let severity: String
        let triggerWords: [String]?
        let semanticVariants: [String]? // ignored in AC (regex layer may cover)
    }
    struct Softeners: Decodable { let hedges: [String]?; let emojis: [String]?; let positiveValence: [String]?; let relationshipContext: [String]? }
    struct Settings: Decodable { let defaultSensitivity: String? }
    let version: String?
    let settings: Settings?
    let categories: [Category]?
    let softeners: Softeners?
}

private struct TonePatternsRoot: Decodable {
    struct Entry: Decodable { let id: String; let tone: String; let type: String; let pattern: String; let confidence: Int }
    let engine: TriggerwordsRoot.Engine?
    let patterns: [Entry]
}

private struct PhraseEdgesRoot: Decodable {
    struct Edge: Decodable { let pattern: String; let boost: Double; let category: String; let toneBias: [String:Double]? }
    struct Engine: Decodable { let regexFlags: String? }
    let engine: Engine?
    let edges: [Edge]
}

private struct NegationRoot: Decodable {
    struct Indicator: Decodable { let id: String; let pattern: String; let impact: Double }
    let negation_indicators: [Indicator]
}

private struct SarcasmRoot: Decodable {
    struct Indicator: Decodable { let id: String; let pattern: String; let impact: Double }
    let sarcasm_indicators: [Indicator]
}

private struct SeverityRoot: Decodable {
    struct BlendWeights: Decodable { let triggerScore: Double; let contextScore: Double; let intensityScore: Double; let negationSarcasm: Double; let attachmentAdj: Double; let preferenceAdj: Double }
    struct Defaults: Decodable { let blendWeights: BlendWeights; let minThreshold: Double; let maxThreshold: Double; let hysteresis: Hyst?; let window_ms: Int? }
    struct Hyst: Decodable { let upshift: Double?; let downshift: Double? }
    struct Bands: Decodable { let low: [Double]; let med: [Double]; let high: [Double] }
    struct ToneBands: Decodable { let alert: Bands; let caution: Bands; let clear: Bands }
    let defaults: Defaults
    let severityBands: ToneBands
}

private struct ContextRoot: Decodable {
    struct Context: Decodable { let id: String; let description: String?; let toneCues: [String]?; let confidenceBoosts: [String:Double]? }
    let priorityOrder: [String]
    let contexts: [Context]
}

// MARK: - Tiny Aho–Corasick implementation (Unicode-safe)

private final class AhoCorasick<Payload> {
    final class Node {
        var next: [Character: Node] = [:]
        weak var fail: Node?
        var outs: [Payload] = []
    }
    private let root = Node()

    func add(_ pattern: String, payload: Payload) {
        guard !pattern.isEmpty else { return }
        var node = root
        for ch in pattern { node = node.next[ch] ?? { let n=Node(); node.next[ch]=n; return n }() }
        node.outs.append(payload)
    }
    func build() {
        var q: [Node] = []
        for (_, n) in root.next { n.fail = root; q.append(n) }
        while !q.isEmpty {
            let cur = q.removeFirst()
            for (ch, nxt) in cur.next {
                var f = cur.fail
                while f != nil && f?.next[ch] == nil { f = f?.fail }
                nxt.fail = f?.next[ch] ?? root
                if let add = nxt.fail?.outs { nxt.outs.append(contentsOf: add) }
                q.append(nxt)
            }
        }
    }
    func search(in text: String, onMatch: (Payload, String.Index) -> Void) {
        var node = root
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            while node !== root && node.next[ch] == nil { node = node.fail ?? root }
            if let go = node.next[ch] { node = go } else { node = root }
            if !node.outs.isEmpty { node.outs.forEach { onMatch($0, i) } }
            i = text.index(after: i)
        }
    }
}

// MARK: - Engine

public final class ToneAnalysisEngine {

    // Public result with audit
    public struct AnalysisOut {
        public let classification: ToneClassification
        public let band: String // low/med/high for the primary tone
        public let audit: Audit
    }
    public struct Audit {
        public let triggerScore: Double
        public let contextScore: Double
        public let intensityScore: Double
        public let negSarScore: Double
        public let attachmentsAdj: Double
        public let prefsAdj: Double
        public let rawTotals: (alert: Double, caution: Double, clear: Double)
        public let topContexts: [String]
        public let topTriggers: [String]
        public let regexHits: [String]
    }

    // Compiled assets
    private var twTrie = AhoCorasick<TriggerHit>()
    private var profTrie = AhoCorasick<ProfHit>()
    private var softTrie = AhoCorasick<String>()

    private var toneRegex: [(ToneStatus, NSRegularExpression, Int)] = [] // (tone, regex, confidence)
    private var edgeRegex: [(NSRegularExpression, Double, String, [String:Double]?)] = [] // (regex, boost, category, toneBias)
    private var negRegex: [(NSRegularExpression, Double)] = []
    private var sarcRegex: [(NSRegularExpression, Double)] = []

    // Severity & weights
    private var blendWeights = (trigger: 0.45, context: 0.20, intensity: 0.12, negsar: 0.08, attach: 0.10, prefs: 0.05)
    private var bands: [ToneStatus:(low: [Double], med: [Double], high: [Double])] = [:]
    private var thresholdCap = (min: 0.30, max: 0.85)

    // Context cues (simple literal regex OR’s)
    private var contextCues: [(id: String, regex: NSRegularExpression, boosts: [String:Double])] = []

    // Multipliers place-holders (from weight_modifiers / user_prefs / attachment_overrides)
    public struct Multipliers {
        public var attachment: AttachmentStyle = .unknown
        public var profileKey: String = "balanced" // one of your profiles
        public var userToneOverrides: (alert: Double, caution: Double, clear: Double) = (0,0,0)
        public init() {}
    }

    // Trigger payloads
    private struct TriggerHit { let tone: ToneStatus; let value: Double; let label: String }
    private enum ProfSeverity { case mild, moderate, strong }
    private struct ProfHit { let severity: ProfSeverity }

    public init() {}

    // MARK: Loading/compiling

    public func load(
        triggerwordsJSON: Data?,
        profanityJSON: Data?,
        tonePatternsJSON: Data?,
        phraseEdgesJSON: Data?,
        negationJSON: Data?,
        sarcasmJSON: Data?,
        severityJSON: Data?,
        contextJSON: Data?
    ) {
        // 1) Triggerwords → AC
        if let data = triggerwordsJSON, let root = try? JSONDecoder().decode(TriggerwordsRoot.self, from: data) {
            func add(_ sec: TriggerwordsRoot.Section?, tone: ToneStatus) {
                guard let groups = sec?.triggerwords else { return }
                for g in groups {
                    let base = Double(g.intensity) / 100.0
                    let canon = g.text
                    twTrie.add(normalize(canon), payload: .init(tone: tone, value: base, label: canon))
                    (g.variants ?? []).forEach { v in
                        twTrie.add(normalize(v), payload: .init(tone: tone, value: base * 0.95, label: canon))
                    }
                }
            }
            add(root.alert, tone: .alert)
            add(root.caution, tone: .caution)
            add(root.clear, tone: .clear)
            twTrie.build()
        }

        // 2) Profanity → AC (plus softeners)
        if let data = profanityJSON, let root = try? JSONDecoder().decode(ProfanityRoot.self, from: data) {
            for cat in root.categories ?? [] {
                guard let words = cat.triggerWords else { continue }
                let sev: ProfSeverity = cat.id.contains("STRONG") ? .strong : (cat.id.contains("MODERATE") ? .moderate : .mild)
                for w in words { profTrie.add(normalize(w), payload: .init(severity: sev)) }
            }
            let s = root.softeners
            for list in [s?.hedges, s?.emojis, s?.positiveValence, s?.relationshipContext] {
                (list ?? []).forEach { softTrie.add(normalize($0), payload: $0) }
            }
            profTrie.build(); softTrie.build()
        }

        // 3) tone_patterns (regex)
        if let data = tonePatternsJSON, let root = try? JSONDecoder().decode(TonePatternsRoot.self, from: data) {
            for e in root.patterns { if let re = try? NSRegularExpression(pattern: e.pattern, options: [.caseInsensitive]) { toneRegex.append((mapTone(e.tone), re, e.confidence)) } }
        }

        // 4) phrase_edges (regex)
        if let data = phraseEdgesJSON, let root = try? JSONDecoder().decode(PhraseEdgesRoot.self, from: data) {
            for e in root.edges { if let re = try? NSRegularExpression(pattern: e.pattern, options: [.caseInsensitive]) { edgeRegex.append((re, e.boost, e.category, e.toneBias)) } }
        }

        // 5) negation
        if let data = negationJSON, let root = try? JSONDecoder().decode(NegationRoot.self, from: data) {
            for n in root.negation_indicators { if let re = try? NSRegularExpression(pattern: n.pattern, options: [.caseInsensitive]) { negRegex.append((re, n.impact)) } }
        }

        // 6) sarcasm
        if let data = sarcasmJSON, let root = try? JSONDecoder().decode(SarcasmRoot.self, from: data) {
            for s in root.sarcasm_indicators { if let re = try? NSRegularExpression(pattern: s.pattern, options: [.caseInsensitive]) { sarcRegex.append((re, s.impact)) } }
        }

        // 7) severity + bands + weights
        if let data = severityJSON, let root = try? JSONDecoder().decode(SeverityRoot.self, from: data) {
            let bw = root.defaults.blendWeights
            blendWeights = (bw.triggerScore, bw.contextScore, bw.intensityScore, bw.negationSarcasm, bw.attachmentAdj, bw.preferenceAdj)
            thresholdCap = (root.defaults.minThreshold, root.defaults.maxThreshold)
            bands[.alert]   = (low: root.severityBands.alert.low,   med: root.severityBands.alert.med,   high: root.severityBands.alert.high)
            bands[.caution] = (low: root.severityBands.caution.low, med: root.severityBands.caution.med, high: root.severityBands.caution.high)
            bands[.clear]   = (low: root.severityBands.clear.low,   med: root.severityBands.clear.med,   high: root.severityBands.clear.high)
        }

        // 8) context cues (from context_classifier toneCues)
        if let data = contextJSON, let root = try? JSONDecoder().decode(ContextRoot.self, from: data) {
            for c in root.contexts {
                let unionPattern = (c.toneCues ?? []).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
                guard !unionPattern.isEmpty else { continue }
                if let re = try? NSRegularExpression(pattern: "\\b(?:" + unionPattern + ")\\b", options: [.caseInsensitive]) {
                    contextCues.append((id: c.id, regex: re, boosts: c.confidenceBoosts ?? [:]))
                }
            }
        }
    }

    // MARK: Analyze

    public func analyze(text raw: String, attachment: AttachmentStyle = .unknown, prefsToneDelta: (alert: Double, caution: Double, clear: Double)? = nil) -> AnalysisOut {
        let text = normalize(raw)

        // Triggerwords (AC)
        var trigScores = (alert: 0.0, caution: 0.0, clear: 0.0)
        var topTriggers: [String] = []
        var trigSeen = Set<String>()
        var trigHits = 0
        twTrie.search(in: text) { p, _ in
            if trigHits >= 6 { return } // cap like your JSON
            switch p.tone { case .alert: trigScores.alert += p.value; case .caution: trigScores.caution += p.value; case .clear: trigScores.clear += p.value }
            if !trigSeen.contains(p.label) { topTriggers.append(p.label); trigSeen.insert(p.label) }
            trigHits += 1
        }
        let triggerScore = max(trigScores.alert, trigScores.caution, trigScores.clear)

        // Context
        var ctxScore = 0.0
        var topCtx: [String] = []
        for (id, re, boosts) in contextCues {
            if re.firstMatch(in: text, options: [], range: text.nsRange) != nil {
                // we convert boosts to a single scalar by taking max
                let s = boosts.values.max() ?? 0
                ctxScore = max(ctxScore, s)
                topCtx.append(id)
                if topCtx.count >= 2 { break }
            }
        }

        // Regex: tone_patterns
        var regexScore = (alert: 0.0, caution: 0.0, clear: 0.0)
        var regexHits: [String] = []
        var regexCount = 0
        for (tone, re, conf) in toneRegex {
            if regexCount >= 6 { break }
            if re.firstMatch(in: text, options: [], range: text.nsRange) != nil {
                let v = Double(conf) / 100.0 * 0.6 // tame weight
                switch tone { case .alert: regexScore.alert += v; case .caution: regexScore.caution += v; case .clear: regexScore.clear += v }
                regexHits.append("pattern:")
                regexCount += 1
            }
        }

        // Phrase edges (extra intensity nudges)
        var intensityScore = 0.0
        for (re, boost, _, _) in edgeRegex {
            if re.firstMatch(in: text, options: [], range: text.nsRange) != nil { intensityScore += boost }
        }

        // Profanity (AC) + softeners
        var strong = 0, moderate = 0, mild = 0
        profTrie.search(in: text) { p, _ in
            switch p.severity { case .strong: strong += 1; case .moderate: moderate += 1; case .mild: mild += 1 }
        }
        var softCount = 0
        softTrie.search(in: text) { _, _ in softCount += 1 }
        var negSarScore = 0.0
        if strong > 0 { negSarScore += 0.20 }
        if moderate > 0 { negSarScore += 0.10 }
        if mild > 0 { negSarScore += 0.06 }
        if softCount > 0 { negSarScore -= 0.05 }

        // Negation / sarcasm regex impacts (aggregate)
        for (re, impact) in negRegex { if re.firstMatch(in: text, options: [], range: text.nsRange) != nil { negSarScore += impact } }
        for (re, impact) in sarcRegex { if re.firstMatch(in: text, options: [], range: text.nsRange) != nil { negSarScore += impact } }

        // Aggregate per defaults.blendWeights
        let w = blendWeights
        var alertTotal   = clamp(trigScores.alert   + regexScore.alert, 0, 1)
        var cautionTotal = clamp(trigScores.caution + regexScore.caution, 0, 1)
        var clearTotal   = clamp(trigScores.clear   + regexScore.clear, 0, 1)

        // Mix in components
        let mix = w.trigger * triggerScore + w.context * ctxScore + w.intensity * intensityScore + w.negsar * negSarScore
        // push mix into each tone bucket proportionally to its partials
        func distribute(_ base: Double, into tone: ToneStatus) -> Double { return clamp(base * (tone == .alert ? alertTotal : tone == .caution ? cautionTotal : clearTotal), thresholdCap.min, thresholdCap.max) }
        alertTotal   = distribute(mix, into: .alert)
        cautionTotal = distribute(mix, into: .caution)
        clearTotal   = distribute(mix, into: .clear)

        // Attachment & user prefs deltas (small, linear)
        var attachAdj = 0.0
        switch attachment {
        case .anxious:   attachAdj = 0.02
        case .avoidant:  attachAdj = -0.01
        case .disorganized: attachAdj = 0.03
        case .secure, .unknown: attachAdj = 0.0
        }
        let prefs = prefsToneDelta ?? (0,0,0)
        alertTotal   = clamp(alertTotal   + w.attach * attachAdj + w.prefs * prefs.alert,   thresholdCap.min, thresholdCap.max)
        cautionTotal = clamp(cautionTotal + w.attach * attachAdj + w.prefs * prefs.caution, thresholdCap.min, thresholdCap.max)
        clearTotal   = clamp(clearTotal   + w.attach * attachAdj + w.prefs * prefs.clear,   thresholdCap.min, thresholdCap.max)

        // Winner + secondary per policy.secondaryToneDelta ~ 0.03
        let triples: [(ToneStatus, Double)] = [(.alert, alertTotal), (.caution, cautionTotal), (.clear, clearTotal)].sorted { $0.1 > $1.1 }
        let primary = triples[0]
        let secondary = (triples.count > 1 && (primary.1 - triples[1].1) <= 0.03) ? triples[1].0 : nil

        // Band
        let band = bandFor(primary.0, score: primary.1)

        let classification = ToneClassification(primaryTone: primary.0, confidence: Float(primary.1), secondaryTones: secondary != nil ? [secondary!] : [], reasoning: "")

        let audit = Audit(
            triggerScore: triggerScore,
            contextScore: ctxScore,
            intensityScore: intensityScore,
            negSarScore: negSarScore,
            attachmentsAdj: attachAdj,
            prefsAdj: (prefs.alert + prefs.caution + prefs.clear) / 3.0,
            rawTotals: (alertTotal, cautionTotal, clearTotal),
            topContexts: topCtx,
            topTriggers: topTriggers,
            regexHits: regexHits
        )
        return AnalysisOut(classification: classification, band: band, audit: audit)
    }

    // MARK: - Helpers

    private func mapTone(_ s: String) -> ToneStatus { switch s.lowercased() { case "alert": return .alert; case "caution": return .caution; default: return .clear } }

    private func bandFor(_ tone: ToneStatus, score: Double) -> String {
        guard let b = bands[tone] else { return "low" }
        func inRange(_ r: [Double]) -> Bool { r.count == 2 && score >= r[0] && score < r[1] }
        if inRange(b.high) { return "high" }
        if inRange(b.med)  { return "med" }
        return "low"
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { return min(max(v, lo), hi) }

    private func normalize(_ s: String) -> String {
        // mirror your engine normalize: lower + trim + squash spaces; leave punctuation for regex anchors
        let lowered = s.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let squashed = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return squashed
    }
}

// MARK: - NSRange helper
private extension String { var nsRange: NSRange { NSRange(startIndex..<endIndex, in: self) } }
