// api/_lib/services/toneAnalysis.ts
/* ============================================================================
  UNSAID — ADVANCED TONE ANALYSIS (TypeScript, JSON-first)
  - Realtime token stream (clear/caution/alert) + sentence finalize
  - spaCy refinement (lemmas, negation scope, POS)
  - JSON-driven: toneBucketMapping, intensityModifiers, toneTriggerWords, etc.
  - Meta JSONs integrated: weightModifiers, guardrailConfig, profanityLexicons, learningSignals, evaluationTones
  - No network calls; no LLMs in the hot path
  - Compatibility exports kept (loadAllData, mapToneToBuckets, createToneAnalyzer, MLAdvancedToneAnalyzer)
============================================================================ */

import { logger } from '../logger';
import { dataLoader } from './dataLoader';
import { processWithSpacy, processWithSpacySync } from './spacyBridge';

// After imports & before classes
const contextConfigData: any = dataLoader.get('contextClassifier') || {};
const ENGINE = contextConfigData.engine || {};
const CTX_INDEX: Record<string, any> = Object.fromEntries(
  (Array.isArray(contextConfigData.contexts) ? contextConfigData.contexts : []).map((c: any) => [c.id, c])
);

// Handy sets from engine
const GENERIC_CLEAR_STOPS = new Set<string>(
  (ENGINE?.genericTokens?.globalStop || []).concat(ENGINE?.genericTokens?.pronouns || []).map((s:string)=>s.toLowerCase())
);
const CLEAR_MIN_TOKENS = ENGINE?.bucketGuards?.minEvidenceTokensByBucket?.clear ?? 2;
const CLEAR_OVERSHADOW = ENGINE?.bucketGuards?.clear?.overshadowedBy || { bucket: 'alert', atOrAbove: 0.22, ratioRequiredForClear: 1.75 };
const CLEAR_DAMPEN_ESCALATORY = ENGINE?.bucketGuards?.clear?.dampenIfEscalatoryContextsActive ?? 0.35;
const PREFER_CAUTION_IF_BOTH = ENGINE?.bucketGuards?.caution?.preferIfClearAndAlertBoth ?? 0.18;

// -----------------------------
// Semantic Backbone Configuration
// -----------------------------
const ENABLE_SB = process.env.ENABLE_SEMANTIC_BACKBONE === '1';

type ToneLabel = 'clear'|'caution'|'alert';

/**
 * Apply semantic backbone nudges to tone analysis results
 * Matches clusters/contexts from semantic_thesaurus.json and applies bounded bias
 */
function applySemanticBackboneNudges(
  text: string,
  tone: { classification: string; confidence: number },
  contextLabel: string
): {
  tone: { classification: ToneLabel | string; confidence: number };
  contextLabel: string;
  debug?: any;
} {
  const sb = dataLoader.getSemanticThesaurus();
  if (!ENABLE_SB || !sb) {
    return { tone, contextLabel };
  }

  // --- naive hybrid match (regex + lexical); fast & safe ---
  const hits: Array<{id: string; score: number; contexts: string[]}> = [];
  const lower = text.toLowerCase();

  for (const c of (sb.clusters ?? [])) {
    let s = 0;
    
    // Check regex patterns
    for (const r of (c.match?.regex ?? [])) {
      try { 
        if (new RegExp(r, 'i').test(text)) s += 1.0; 
      } catch (e) {
        // Skip invalid regex patterns
      }
    }
    
    // Check lexical matches
    for (const t of (c.match?.lexical ?? [])) {
      if (lower.includes(t.toLowerCase())) s += 0.6;
    }
    
    if (s > 0) {
      hits.push({ 
        id: c.id, 
        score: s, 
        contexts: c.contextLinks ?? [] 
      });
    }
  }
  
  hits.sort((a, b) => b.score - a.score);

  // collect context biases
  let biasAlert = 0, biasCaution = 0, biasClear = 0;
  const ctxIds = new Set<string>(hits.flatMap(h => h.contexts));
  
  for (const ctx of (sb.contexts ?? [])) {
    if (!ctxIds.has(ctx.id)) continue;
    const b = ctx.bias || {};
    biasAlert += b.alert ?? 0;
    biasCaution += b.caution ?? 0;
    biasClear += b.clear ?? 0;
  }

  // reverse register / sarcasm dampeners from settings
  const rr = sb.settings?.reverseRegisterRule;
  const irony = sb.settings?.ironySarcasm;
  let damp = 1.0;
  
  if (rr?.enabled) {
    const banterMarkers = rr.banter_markers ?? [];
    if (banterMarkers.some((m: string) => lower.includes(m))) {
      damp *= rr.dampenMultiplier ?? 0.6;
    }
  }
  
  if (irony?.enabled) {
    const eye = new Set(irony.signals?.emoji_eye_roll ?? []);
    if (Array.from(eye).some(e => typeof e === 'string' && text.includes(e))) {
      biasAlert += (sb.settings?.thresholds?.irony_override ?? 0.65) * 0.05;
    }
  }

  // map current classification to deltas
  const cls = tone.classification as ToneLabel | string;
  const conf = tone.confidence;

  const delta =
    (cls === 'alert') ? biasAlert :
    (cls === 'caution') ? biasCaution :
    (cls === 'clear') ? biasClear : 0;

  // apply small, bounded nudges (using existing clamp01 function from file)
  const nudgedConf = Math.max(0, Math.min(1, conf * damp + Math.max(-0.06, Math.min(0.06, delta))));

  // optionally tighten context label from strongest context
  let outCtx = contextLabel;
  if (ctxIds.has('CTX_CONFLICT')) outCtx = 'conflict';
  else if (ctxIds.has('CTX_REPAIR')) outCtx = 'repair';
  else if (ctxIds.has('CTX_PLANNING')) outCtx = 'planning';
  else if (ctxIds.has('CTX_BOUNDARY')) outCtx = 'boundary';

  return {
    tone: { classification: cls, confidence: nudgedConf },
    contextLabel: outCtx,
    debug: { 
      hits: hits.slice(0, 5), 
      bias: { biasAlert, biasCaution, biasClear }, 
      damp 
    }
  };
}

// -----------------------------
// Shared utility for safe array conversion
// -----------------------------
function arrify<T = any>(x: unknown): T[] {
  if (x == null) return [];
  if (Array.isArray(x)) return x as T[];
  if (typeof x === 'object') return Object.values(x as Record<string, unknown>).flatMap(v => arrify<T>(v));
  return [x as T];
}

// -----------------------------
// Types
// -----------------------------
type Bucket = 'clear'|'caution'|'alert';

export interface AdvancedToneResult {
  primary_tone: string;
  confidence: number;
  emotions: {
    joy: number;
    anger: number;
    fear: number;
    sadness: number;
    analytical: number;
    confident: number;
    tentative: number;
  };
  intensity: number;
  sentiment_score: number;
  linguistic_features: {
    formality_level: number;
    emotional_complexity: number;
    assertiveness: number;
    empathy_indicators: string[];
    potential_misunderstandings: string[];
  };
  context_analysis: {
    appropriateness_score: number;
    relationship_impact: 'positive' | 'neutral' | 'negative';
    suggested_adjustments: string[];
  };
  attachment_insights?: {
    likely_attachment_response: string;
    triggered_patterns: string[];
    healing_suggestions: string[];
  };
}

export interface ToneAnalysisOptions {
  context: string;
  userProfile?: any;
  attachmentStyle?: string;
  relationshipStage?: string;
  includeAttachmentInsights?: boolean;
  deepAnalysis?: boolean;
  isNewUser?: boolean;
}

// -----------------------------
// Utils
// -----------------------------
const clamp01 = (x:number)=>Math.max(0,Math.min(1,x));

function softmax3(log: Record<Bucket, number>): Record<Bucket, number> {
  const m = Math.max(log.clear, log.caution, log.alert, 0);
  const ec = Math.exp((log.clear ?? 0) - m);
  const eo = Math.exp((log.caution ?? 0) - m);
  const ea = Math.exp((log.alert ?? 0) - m);
  const Z = ec + eo + ea || 1;
  return { clear: ec/Z, caution: eo/Z, alert: ea/Z };
}

function normalize3(d: Record<Bucket, number>): Record<Bucket, number> {
  const s = (d.clear ?? 0) + (d.caution ?? 0) + (d.alert ?? 0) || 1;
  return { clear: (d.clear ?? 0)/s, caution: (d.caution ?? 0)/s, alert: (d.alert ?? 0)/s };
}

function plattCalibrate(conf: number, ctx: string) {
  const ev = dataLoader.get('evaluationTones');
  const ls = dataLoader.get('learningSignals');
  // base Platt
  const p = ev?.platt?.[ctx] ?? ev?.platt?.general ?? { a: 1, b: 0 };
  let calibrated = 1 / (1 + Math.exp(-(p.a*conf + p.b)));
  // light online adjustment from learning signals (context-wide slope/offset)
  const adj = ls?.plattAdjust?.[ctx] ?? { a: 1, b: 0 };
  calibrated = 1 / (1 + Math.exp(-(adj.a*calibrated + adj.b)));
  return clamp01(calibrated);
}

// -----------------------------
// spaCy Lite Adapter
// -----------------------------
type SpacyLite = {
  tokens: { text: string; lemma: string; pos: string; i: number }[];
  sents: { start: number; end: number }[];
  negScopes: Array<{ label: string; start: number; end: number }>;
  sarcasmCue: boolean;
  contextLabel?: string;
};

async function spacyLite(text: string, hintContext?: string): Promise<SpacyLite> {
  const r = await processWithSpacy(text, 'finalize');

  // Extract tokens from the actual spaCy response structure
  const tokens = (r as any).tokens || [];
  const tokensMapped = tokens.map((t: any, i: number) => ({
    text: t.text || '',
    lemma: (t.lemma || t.text || '').toLowerCase(),
    pos: (t.pos || 'X').toUpperCase(),
    i
  }));

  // Extract negation scopes - using simplified approach since detailed deps may not be available
  const negScopes: Array<{label: string; start:number;end:number}> = [];
  const deps = (r as any).deps || [];
  for (const dep of deps) {
    if (dep && dep.rel === 'neg') {
      const subtreeSpan = (r as any).subtreeSpan;
      const span = subtreeSpan?.[dep.head];
      if (span) negScopes.push({ label: 'NEG', start: span.start, end: span.end });
    }
  }

  // Extract sentence boundaries
  const sents = (r as any).sents || [];
  const sentsMapped = sents.map((s: any) => ({ start: s.start || 0, end: s.end || text.length }));

  return {
    tokens: tokensMapped,
    sents: sentsMapped,
    negScopes,
    sarcasmCue: !!(r as any).sarcasm?.present,
    contextLabel: (r as any).context?.label ?? hintContext ?? 'general'
  };
}

function spacyLiteSync(text: string, hintContext?: string): SpacyLite {
  const r = processWithSpacySync(text, 'finalize');

  // Extract tokens from the actual spaCy response structure
  const tokens = (r as any).tokens || [];
  const tokensMapped = tokens.map((t: any, i: number) => ({
    text: t.text || '',
    lemma: (t.lemma || t.text || '').toLowerCase(),
    pos: (t.pos || 'X').toUpperCase(),
    i
  }));

  // Extract negation scopes - using simplified approach since detailed deps may not be available
  const negScopes: Array<{label: string; start:number;end:number}> = [];
  const deps = (r as any).deps || [];
  for (const dep of deps) {
    if (dep && dep.rel === 'neg') {
      const subtreeSpan = (r as any).subtreeSpan;
      const span = subtreeSpan?.[dep.head];
      if (span) negScopes.push({ label: 'NEG', start: span.start, end: span.end });
    }
  }

  // Extract sentence boundaries
  const sents = (r as any).sents || [];
  const sentsMapped = sents.map((s: any) => ({ start: s.start || 0, end: s.end || text.length }));

  return {
    tokens: tokensMapped,
    sents: sentsMapped,
    negScopes,
    sarcasmCue: !!(r as any).sarcasm?.present,
    contextLabel: (r as any).context?.label ?? hintContext ?? 'general'
  };
}

// -----------------------------
// Aho-Corasick automaton for efficient multi-pattern matching
// -----------------------------
class AhoCorasickNode {
  children = new Map<string, AhoCorasickNode>();
  failure: AhoCorasickNode | null = null;
  output: { bucket: Bucket; weight: number; term: string }[] = [];
}

class AhoCorasickAutomaton {
  private root = new AhoCorasickNode();
  private built = false;

  addPattern(pattern: string, bucket: Bucket, weight: number) {
    let node = this.root;
    const terms = pattern.split(' ');
    
    for (const term of terms) {
      if (!node.children.has(term)) {
        node.children.set(term, new AhoCorasickNode());
      }
      node = node.children.get(term)!;
    }
    
    node.output.push({ bucket, weight, term: pattern });
    this.built = false; // Mark as needing rebuild
  }

  build() {
    if (this.built) return;
    
    // Build failure links using BFS
    const queue: AhoCorasickNode[] = [];
    
    // Initialize first level
    for (const child of Array.from(this.root.children.values())) {
      child.failure = this.root;
      queue.push(child);
    }
    
    // Build failure links for deeper levels
    while (queue.length > 0) {
      const currentNode = queue.shift()!;
      
      for (const [char, childNode] of Array.from(currentNode.children)) {
        queue.push(childNode);
        
        let failureNode = currentNode.failure;
        while (failureNode !== null && !failureNode.children.has(char)) {
          failureNode = failureNode.failure;
        }
        
        if (failureNode === null) {
          childNode.failure = this.root;
        } else {
          childNode.failure = failureNode.children.get(char)!;
          // Add failure node's output to current node's output
          childNode.output.push(...childNode.failure.output);
        }
      }
    }
    
    this.built = true;
  }

  search(tokens: string[]): { bucket: Bucket; weight: number; term: string; start: number; end: number }[] {
    this.build();
    
    const results: { bucket: Bucket; weight: number; term: string; start: number; end: number }[] = [];
    let currentNode = this.root;
    
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      
      // Follow failure links until we find a match or reach root
      while (currentNode !== this.root && !currentNode.children.has(token)) {
        currentNode = currentNode.failure!;
      }
      
      if (currentNode.children.has(token)) {
        currentNode = currentNode.children.get(token)!;
        
        // Check for pattern matches at this position
        for (const match of currentNode.output) {
          const termLength = match.term.split(' ').length;
          const start = i - termLength + 1;
          results.push({
            bucket: match.bucket,
            weight: match.weight,
            term: match.term,
            start: start,
            end: i
          });
        }
      }
    }
    
    return results;
  }
}

// -----------------------------
// Enhanced Context Detection System
// -----------------------------

interface WeightedCue {
  pattern: string;
  weight: number;
  type: 'token' | 'ngram' | 'regex';
}

interface ContextConfig {
  id: string;
  context: string;
  priority: number;
  polarity: 'escalatory' | 'deescalatory' | 'neutral';
  windowTokens: number;
  scope: 'local' | 'message' | 'session';
  toneCues: string[];
  toneCuesWeighted?: WeightedCue[];
  counterCues?: string[];
  positionBoost?: { start: number; end: number; allCaps: number };
  repeatDecay?: number;
  cooldown_ms?: number;
  maxBoostsPerMessage?: number;
  excludeIfContexts?: string[];
  requiresAny?: string[];
  deescalates?: string[];
  severity?: Record<Bucket, number>;
  confidenceBoosts?: Record<Bucket, number>;
  attachmentGates?: Record<string, { allow?: string[]; block?: string[]; dampening?: number }>;
}

class ContextDetector {
  private config: ContextConfig;
  private weightedRegexes: { regex: RegExp; weight: number }[] = [];
  private counterRegexes: RegExp[] = [];
  private lastHit = 0;
  private messageBoosts = 0;

  constructor(config: ContextConfig) {
    this.config = config;
    this.initializePatterns();
  }

  private initializePatterns() {
    // Compile weighted patterns
    if (this.config.toneCuesWeighted) {
      for (const cue of this.config.toneCuesWeighted) {
        try {
          if (cue.type === 'regex') {
            this.weightedRegexes.push({ 
              regex: new RegExp(cue.pattern, 'gi'), 
              weight: cue.weight 
            });
          } else if (cue.type === 'token' || cue.type === 'ngram') {
            // Convert to word boundary regex for exact matching
            const escaped = cue.pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            this.weightedRegexes.push({ 
              regex: new RegExp(`\\b${escaped}\\b`, 'gi'), 
              weight: cue.weight 
            });
          }
        } catch (error) {
          logger.warn(`Failed to compile pattern for ${this.config.id}: ${cue.pattern}`, error);
        }
      }
    }

    // Compile counter-cue patterns
    if (this.config.counterCues) {
      for (const counterCue of this.config.counterCues) {
        try {
          const escaped = counterCue.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          this.counterRegexes.push(new RegExp(`\\b${escaped}\\b`, 'gi'));
        } catch (error) {
          logger.warn(`Failed to compile counter-cue for ${this.config.id}: ${counterCue}`, error);
        }
      }
    }
  }

  detectInWindow(tokens: string[], windowStart: number = 0): {
    score: number;
    hits: Array<{ match: string; weight: number; position: number }>;
    counterHits: string[];
    dampened: boolean;
  } {
    const now = Date.now();
    const text = tokens.slice(windowStart, windowStart + (this.config.windowTokens || 32)).join(' ');
    
    // Check cooldown
    if (this.config.cooldown_ms && (now - this.lastHit) < this.config.cooldown_ms) {
      return { score: 0, hits: [], counterHits: [], dampened: true };
    }

    // Check saturation
    if (this.config.maxBoostsPerMessage && this.messageBoosts >= this.config.maxBoostsPerMessage) {
      return { score: 0, hits: [], counterHits: [], dampened: true };
    }

    let score = 0;
    const hits: Array<{ match: string; weight: number; position: number }> = [];
    const counterHits: string[] = [];

    // Check basic tone cues
    for (const cue of this.config.toneCues) {
      const escaped = cue.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const regex = new RegExp(`\\b${escaped}\\b`, 'gi');
      let match;
      while ((match = regex.exec(text)) !== null) {
        const position = match.index / text.length; // Normalized position
        hits.push({ match: cue, weight: 1.0, position });
        score += 1.0;
      }
    }

    // Check weighted patterns
    for (const { regex, weight } of this.weightedRegexes) {
      let match;
      while ((match = regex.exec(text)) !== null) {
        const position = match.index / text.length;
        hits.push({ match: match[0], weight, position });
        score += weight;
      }
    }

    // Check counter-cues
    for (const counterRegex of this.counterRegexes) {
      let match;
      while ((match = counterRegex.exec(text)) !== null) {
        counterHits.push(match[0]);
      }
    }

    // Apply counter-cue dampening
    if (counterHits.length > 0) {
      score *= 0.6; // Default dampening factor
    }

    // Apply position boosts
    if (this.config.positionBoost && hits.length > 0) {
      for (const hit of hits) {
        if (hit.position < 0.2) { // Start of message
          score += this.config.positionBoost.start * hit.weight;
        } else if (hit.position > 0.8) { // End of message
          score += this.config.positionBoost.end * hit.weight;
        }
      }

      // Check for all caps
      if (this.config.positionBoost.allCaps && /[A-Z]{3,}/.test(text)) {
        score += this.config.positionBoost.allCaps;
      }
    }

    // Apply repeat decay
    if (this.config.repeatDecay && hits.length > 1) {
      const uniqueMatches = new Set(hits.map(h => h.match.toLowerCase()));
      if (uniqueMatches.size < hits.length) {
        const repetitions = hits.length - uniqueMatches.size;
        score *= Math.pow(this.config.repeatDecay, repetitions);
      }
    }

    if (score > 0) {
      this.lastHit = now;
      this.messageBoosts++;
    }

    return { score, hits, counterHits, dampened: false };
  }

  resetMessageState() {
    this.messageBoosts = 0;
  }

  getConfig(): ContextConfig {
    return this.config;
  }
}

// -----------------------------
// JSON-backed detectors
// -----------------------------
class ToneDetectors {
  private trigByLen = new Map<number, {term: string, bucket: Bucket, w: number}[]>();
  private ahoCorasick = new AhoCorasickAutomaton(); // ✅ New Aho-Corasick automaton
  private ahoMode: 'aho' | 'fallback' | 'hybrid' =
    (process.env.AHO_MODE as any) || 'hybrid';
  private oneGram: Array<{ term: string; bucket: Bucket; w: number }> = [];
  private oneGramMap = new Map<string, Array<{ bucket: Bucket; w: number }>>();
  private negRegexes: RegExp[] = [];
  private sarcRegexes: RegExp[] = [];
  private edgeRegexes: { re: RegExp, cat: string, weight?: number }[] = [];
  private intensifiers: { re: RegExp, mult: number }[] = [];
  private profanity: string[] = [];
  private tonePatternRegexes: { re: RegExp, bucket: Bucket, weight: number }[] = [];
  
  // ✅ Enhanced context detection system
  private contextDetectors = new Map<string, ContextDetector>();
  private contextHitHistory = new Map<string, { lastHit: number; hitCount: number }>();
  
  constructor() {
    // Remove async initialization - will be lazy & sync
  }

  private initSyncIfNeeded() {
    logger.info('ToneDetectors.initSyncIfNeeded called', { alreadyInitialized: this.trigByLen.size > 0 });
    if (this.trigByLen.size > 0) return; // Already initialized

    // DataLoader should already be initialized by ensureBoot()
    if (!dataLoader.isInitialized()) {
      logger.warn('DataLoader not initialized in ToneDetectors.initSyncIfNeeded');
      return;
    }

    logger.info('Starting ToneDetectors initialization');

    const trig = dataLoader.get('toneTriggerWords') || dataLoader.get('toneTriggerwords');
    const negP = dataLoader.get('negationPatterns') || dataLoader.get('negationIndicators');
    const sarc = dataLoader.get('sarcasmIndicators');
    const edges = dataLoader.get('phraseEdges');
    const inten = dataLoader.get('intensityModifiers');
    const prof  = dataLoader.get('profanityLexicons');

    const push = (t: string, bucket: Bucket, w: number) => {
      const normalizedTerm = this.normalizeText(t);
      const L = normalizedTerm.split(/\s+/).length;
      const arr = this.trigByLen.get(L) || [];
      arr.push({ term: normalizedTerm, bucket, w });
      this.trigByLen.set(L, arr);
      
      // NEW: track 1-grams for O(1) lookup in hybrid mode
      if (L === 1) {
        this.oneGram.push({ term: normalizedTerm, bucket, w });
      }
      
      // ✅ Also add to Aho-Corasick automaton for O(n) performance
      this.ahoCorasick.addPattern(normalizedTerm, bucket, w);
    };

    // Handle actual tone_triggerwords.json structure:
    // {
    //   "alert": { "triggerwords": [{text, intensity, type, variants, aho, contextTags, metadata}] },
    //   "caution": { "triggerwords": [...] },
    //   "clear": { "triggerwords": [...] }
    // }
    let totalWords = 0;
    for (const bucket of ['clear','caution','alert'] as Bucket[]) {
      const node = trig[bucket];
      if (!node || !node.triggerwords) {
        logger.warn(`No triggerwords found for bucket: ${bucket}`);
        continue;
      }

      const items = node.triggerwords || [];
      logger.info(`Loading ${items.length} triggerwords for bucket: ${bucket}`);
      for (const item of items) {
        const wBase = item.intensity ?? 1.0;
        
        // Apply context multipliers if available
        const contextMultipliers = trig?.weights?.contextMultipliers || {};
        let contextWeight = 1.0;
        if (item.type && contextMultipliers.default && contextMultipliers.default[item.type]) {
          contextWeight = contextMultipliers.default[item.type];
        }
        
        const w = wBase * contextWeight;

        // Use enhanced aho patterns if available, fallback to variants
        const patterns = item.aho || [item.text, ...(item.variants || [])];
        const terms = patterns.filter(Boolean);
        
        for (const t of terms) {
          push(t, bucket, w);
          totalWords++;
        }
        
        // Log metadata for debugging if available
        if (item.metadata) {
          logger.debug(`Loaded triggerword: ${item.text}`, {
            bucket,
            intensity: w,
            type: item.type,
            source: item.metadata.source,
            lastUpdated: item.metadata.lastUpdated
          });
        }
      }
    }
    logger.info(`Total trigger words loaded: ${totalWords}`);

    // Build oneGramMap for fast unigram lookups
    for (const { term, bucket, w } of this.oneGram) {
      const arr = this.oneGramMap.get(term) || [];
      arr.push({ bucket, w });
      this.oneGramMap.set(term, arr);
    }

    // Load engine configuration for negation and context handling
    const engineConfig = trig?.engine || {};
    if (engineConfig.negation?.enabled) {
      logger.info('Enhanced negation handling enabled', {
        markers: engineConfig.negation.markers?.length || 0,
        scope: engineConfig.negation.scope
      });
    }
    if (engineConfig.contextScopes) {
      logger.info('Context scopes loaded', {
        scopes: Object.keys(engineConfig.contextScopes)
      });
    }

    const safe = (p: string) => { try { return new RegExp(p, 'i'); } catch { return null; } };
    arrify(negP?.patterns ?? negP).forEach((p: string) => { const r = safe(String(p)); if (r) this.negRegexes.push(r); });
    arrify(sarc?.patterns ?? sarc).forEach((p: string) => { const r = safe(String(p)); if (r) this.sarcRegexes.push(r); });
    arrify(edges?.edges ?? edges).forEach((e: any) => { const r = safe(e.pattern); if (r) this.edgeRegexes.push({ re: r, cat: e.category || 'edge', weight: e.weight ?? 1 }); });

    // Support both flat and structured intensity modifiers
    const collectModifiers = () => {
      // flat
      if (Array.isArray(inten?.modifiers)) return inten.modifiers.map((m:any)=>({pattern:m.pattern||m.regex, mult:m.multiplier ?? m.baseMultiplier ?? 1, tone: m.tone, style: m.attachmentStyle, override: m.override }));
      // structured by attachment style
      const out:any[] = [];
      for (const style of Object.keys(inten || {})) {
        const node = inten[style];
        const list = node?.modifiers || [];
        for (const m of list) {
          out.push({ pattern: m.pattern || m.regex, mult: m.multiplier ?? m.baseMultiplier ?? 1, tone: m.tone, style, override: m.override });
        }
      }
      return out;
    };

    const flatMods = collectModifiers();
    flatMods.forEach((m:any) => {
      const r = safe(m.pattern); 
      if (r) this.intensifiers.push({ re: r, mult: m.mult });
    });

    // Extract all triggerWords from profanity lexicon categories
    const profanityWords: string[] = [];
    logger.info(`Profanity lexicon debug: prof=`, prof);
    if (prof?.categories) {
      const categories = arrify(prof.categories);
      logger.info(`Found ${categories.length} profanity categories`);
      categories.forEach((category: any, index: number) => {
        logger.info(`Category ${index}: id=${category.id}, triggerWords=${category.triggerWords}`);
        if (category.triggerWords && Array.isArray(category.triggerWords)) {
          profanityWords.push(...category.triggerWords);
        }
      });
    } else {
      logger.warn(`No profanity categories found in data: prof=`, prof);
    }
    this.profanity = profanityWords;
    logger.info(`Loaded ${profanityWords.length} profanity words: ${profanityWords.slice(0, 10).join(', ')}...`);

    // Load tone patterns (optional, won't break boot if missing)
    const tonePatterns = dataLoader.get('tonePatterns') || dataLoader.get('tone_patterns'); // array
    if (Array.isArray(tonePatterns)) {
      logger.info(`Loading ${tonePatterns.length} tone patterns`);
      for (const p of tonePatterns) {
        const bucket = (['clear','caution','alert'] as Bucket[]).includes(p.tone) ? p.tone : 'caution';
        const w = typeof p.confidence === 'number' ? p.confidence : 0.85;

        // Add exact phrases & semanticVariants to Aho-Corasick
        if (p.type !== 'regex') {
          if (p.pattern) this.ahoCorasick.addPattern(this.normalizeText(p.pattern), bucket, w);
          arrify(p.semanticVariants).forEach((v: string) =>
            this.ahoCorasick.addPattern(this.normalizeText(v), bucket, Math.max(0.5, w * 0.95)));
        }

        // Compile regex patterns
        if (p.type === 'regex' && p.pattern) {
          try { 
            this.tonePatternRegexes.push({ re: new RegExp(p.pattern, 'i'), bucket, weight: w }); 
          } catch (error) {
            logger.warn(`Failed to compile regex pattern: ${p.pattern}`, error);
          }
        }
      }
      logger.info(`Loaded ${this.tonePatternRegexes.length} regex patterns from tone_patterns.json`);
    } else {
      logger.info('No tone_patterns.json found or invalid format, skipping');
    }

    // ✅ Load enhanced context detectors
    const contextData = dataLoader.get('contextClassifier');
    if (contextData?.contexts) {
      logger.info(`Loading ${contextData.contexts.length} context detectors`);
      for (const contextConfig of contextData.contexts) {
        try {
          const detector = new ContextDetector(contextConfig as ContextConfig);
          this.contextDetectors.set(contextConfig.id, detector);
          logger.debug(`Loaded context detector: ${contextConfig.id}`, {
            priority: contextConfig.priority,
            polarity: contextConfig.polarity,
            weightedCues: contextConfig.toneCuesWeighted?.length || 0,
            counterCues: contextConfig.counterCues?.length || 0
          });
        } catch (error) {
          logger.warn(`Failed to load context detector: ${contextConfig.id}`, error);
        }
      }
      logger.info(`Loaded ${this.contextDetectors.size} context detectors`);
    } else {
      logger.warn('No context classifier data found');
    }

    logger.info(`ToneDetectors initialized with ${this.trigByLen.size} trigger word lengths, ${this.profanity.length} profanity words, ${this.tonePatternRegexes.length} tone pattern regexes, ${this.contextDetectors.size} context detectors`);
  }

  // Text normalization for consistent matching
  private normalizeText(text: string): string {
    return text
      .normalize('NFKC')  // Unicode normalization
      .toLowerCase()      // Case folding
      .replace(/\s+/g, ' ')  // Collapse whitespace
      .replace(/[^\w\s]/g, ' ')  // Strip punctuation, replace with space
      .trim();
  }

  // Tokenize normalized text consistently
  private tokenizeNormalized(text: string): string[] {
    return this.normalizeText(text)
      .split(/\s+/)
      .filter(token => token.length > 0);
  }

  scanSurface(tokens: string[]): { bucket: Bucket; weight: number; term: string; start: number; end: number }[] { 
    // Normalize tokens for consistent matching
    const normalizedTokens = tokens.map(t => this.normalizeText(t));
    return this.scan(normalizedTokens); 
  }
  scanLemmas(lemmas: string[]): { bucket: Bucket; weight: number; term: string; start: number; end: number }[] { 
    // Normalize lemmas for consistent matching
    const normalizedLemmas = lemmas.map(l => this.normalizeText(l));
    return this.scan(normalizedLemmas); 
  }

  private regexToneHits(terms: string[]) {
    const hits: { bucket: Bucket; weight: number; term: string; start: number; end: number }[] = [];
    if (this.tonePatternRegexes.length === 0) return hits;

    const fullText = terms.join(' ');
    for (const { re, bucket, weight } of this.tonePatternRegexes) {
      const match = re.exec(fullText);
      if (match) {
        const startChar = match.index || 0;
        const endChar = startChar + match[0].length;
        const startTerm = fullText.substring(0, startChar).split(' ').length - 1;
        const endTerm = Math.min(terms.length - 1, startTerm + match[0].split(' ').length - 1);
        hits.push({ bucket, weight, term: match[0], start: Math.max(0, startTerm), end: Math.max(0, endTerm) });
      }
    }
    return hits;
  }

  private fallbackScan(terms: string[]) {
    // Your existing O(n*m) span scan using this.trigByLen
    const hits: { bucket: Bucket; weight: number; term: string; start: number; end: number }[] = [];
    const MAX_N = Math.max(1, ...Array.from(this.trigByLen.keys(), n => n || 1));
    for (let i = 0; i < terms.length; i++) {
      for (let n = Math.min(MAX_N, terms.length - i); n >= 1; n--) {
        const arr = this.trigByLen.get(n);
        if (!arr || !arr.length) continue;
        const span = terms.slice(i, i + n).join(' ');
        for (const cand of arr) {
          if (span === cand.term) hits.push({ bucket: cand.bucket, weight: cand.w, term: cand.term, start: i, end: i + n - 1 });
        }
      }
    }
    return hits;
  }

  private scanHybrid(terms: string[]) {
    this.initSyncIfNeeded();

    const t0 = Date.now();
    const hits: { bucket: Bucket; weight: number; term: string; start: number; end: number }[] = [];

    // Aho pass (all phrases / ≥2-gram patterns fed during init)
    const ahoHits = this.ahoCorasick.search(terms);
    for (const h of ahoHits) {
      hits.push({ bucket: h.bucket, weight: h.weight, term: h.term, start: h.start, end: h.end });
    }

    // Unigram pass (O(1) per token)
    let uniCount = 0;
    for (let i = 0; i < terms.length; i++) {
      const t = terms[i];
      const arr = this.oneGramMap.get(t);
      if (!arr) continue;
      uniCount += arr.length;
      for (const m of arr) {
        hits.push({ bucket: m.bucket, weight: m.w, term: t, start: i, end: i });
      }
    }

    // Regex patterns (existing)
    const regexHits = this.regexToneHits(terms);
    for (const h of regexHits) hits.push(h);

    // De-dupe identical spans
    const key = (h: any) => `${h.bucket}:${h.term}:${h.start}:${h.end}`;
    const seen = new Set<string>();
    const out: typeof hits = [];
    for (const h of hits) {
      const k = key(h);
      if (!seen.has(k)) { seen.add(k); out.push(h); }
    }

    if ((process.env.DEBUG_TONE ?? '') === '1') {
      logger.info('scanHybrid metrics', {
        tokens: terms.length,
        ahoHits: ahoHits.length,
        unigramMatches: uniCount,
        regexMatches: regexHits.length,
        outCount: out.length,
        ms: Date.now() - t0,
      });
    }
    return out;
  }

  private scan(terms: string[]): { bucket: Bucket; weight: number; term: string; start: number; end: number }[] {
    this.initSyncIfNeeded();

    if ((process.env.DEBUG_TONE ?? '') === '1') {
      logger.info('ToneDetectors.scan', { mode: this.ahoMode, nTerms: terms.length });
    }

    if (this.ahoMode === 'aho') {
      // Aho only + regex
      const ahoHits = this.ahoCorasick.search(terms);
      const regexHits = this.regexToneHits(terms);
      return [...ahoHits, ...regexHits];
    }

    if (this.ahoMode === 'fallback') {
      // Legacy O(n*m) + regex
      const fb = this.fallbackScan(terms);
      const regexHits = this.regexToneHits(terms);
      return [...fb, ...regexHits];
    }

    // default: hybrid
    return this.scanHybrid(terms);
  }

  hasNegation(text: string) { return this.negRegexes.some(r => r.test(text)); }
  hasSarcasm(text: string) { return this.sarcRegexes.some(r => r.test(text)); }

  // ✅ Enhanced context detection with smart schema features
  detectContexts(tokens: string[], attachmentStyle: string = 'secure'): {
    primaryContext: string | null;
    allContexts: Array<{ 
      id: string; 
      score: number; 
      confidence: number;
      boosts: Record<Bucket, number>;
      severity: Record<Bucket, number>;
      dampened: boolean;
    }>;
    deescalated: string[];
  } {
    this.initSyncIfNeeded();
    
    const contextResults: Array<{ 
      id: string; 
      score: number; 
      config: ContextConfig;
      hits: Array<{ match: string; weight: number; position: number }>;
      counterHits: string[];
      dampened: boolean;
    }> = [];

    // Reset message state for all detectors
    for (const detector of Array.from(this.contextDetectors.values())) {
      detector.resetMessageState();
    }

    // Detect all contexts
    for (const [contextId, detector] of Array.from(this.contextDetectors)) {
      const config = detector.getConfig();
      
      // Check attachment gates
      const gates = config.attachmentGates?.[attachmentStyle];
      if (gates) {
        if (gates.block?.includes(config.context)) {
          continue; // Skip blocked contexts for this attachment style
        }
        if (gates.allow && !gates.allow.includes(config.context)) {
          continue; // Skip contexts not in allow list
        }
      }

      // Check requires conditions
      if (config.requiresAny) {
        const hasRequired = config.requiresAny.some(req => 
          tokens.some(token => token.toLowerCase().includes(req.toLowerCase()))
        );
        if (!hasRequired) continue;
      }

      const result = detector.detectInWindow(tokens);
      if (result.score > 0) {
        contextResults.push({
          id: contextId,
          score: result.score,
          config,
          hits: result.hits,
          counterHits: result.counterHits,
          dampened: result.dampened
        });
      }
    }

    // Sort by priority (higher first), then by score
    contextResults.sort((a, b) => {
      const priorityDiff = (b.config.priority || 1) - (a.config.priority || 1);
      if (priorityDiff !== 0) return priorityDiff;
      return b.score - a.score;
    });

    // Apply exclusion rules and deconfliction
    const filteredResults: typeof contextResults = [];
    const excludedContexts = new Set<string>();
    
    for (const result of contextResults) {
      const config = result.config;
      
      // Check if this context should be excluded by higher priority contexts
      if (config.excludeIfContexts) {
        const shouldExclude = config.excludeIfContexts.some(excludeId => 
          filteredResults.some(fr => fr.config.context === excludeId)
        );
        if (shouldExclude) {
          excludedContexts.add(result.id);
          continue;
        }
      }
      
      filteredResults.push(result);
    }

    // Find deescalating contexts
    const deescalated: string[] = [];
    for (const result of filteredResults) {
      if (result.config.deescalates) {
        for (const deescalatedContext of result.config.deescalates) {
          if (filteredResults.some(fr => fr.config.context === deescalatedContext)) {
            deescalated.push(deescalatedContext);
          }
        }
      }
    }

    // Build final results
    const allContexts = filteredResults.map(result => {
      const config = result.config;
      const gates = config.attachmentGates?.[attachmentStyle];
      let finalScore = result.score;
      
      // Apply attachment dampening
      if (gates?.dampening) {
        finalScore *= gates.dampening;
      }

      // Calculate confidence (0-1) based on score and hits
      const confidence = Math.min(1.0, finalScore / Math.max(1, result.hits.length));
      
      // Get boosts and severity adjustments
      const boosts: Record<Bucket, number> = {
        clear: config.confidenceBoosts?.clear || 0,
        caution: config.confidenceBoosts?.caution || 0,
        alert: config.confidenceBoosts?.alert || 0
      };
      
      const severity: Record<Bucket, number> = {
        clear: config.severity?.clear || 0,
        caution: config.severity?.caution || 0,
        alert: config.severity?.alert || 0
      };

      return {
        id: result.id,
        score: finalScore,
        confidence,
        boosts,
        severity,
        dampened: result.dampened
      };
    });

    const primaryContext = allContexts.length > 0 ? allContexts[0].id : null;

    return { primaryContext, allContexts, deescalated };
  }
  edgeHits(text: string) { 
    logger.info('edgeHits method called', { textLength: text.length, edgeRegexCount: this.edgeRegexes.length });
    const out:{cat:string,weight:number}[]=[]; 
    for (const {re,cat,weight} of this.edgeRegexes) {
      if (re.test(text)) out.push({cat, weight: weight ?? 1}); 
    }
    logger.info('edgeHits method completed', { resultCount: out.length });
    return out; 
  }
  intensityBump(text: string) { 
    const cap = 0.3; // Cap per signal to prevent explosion
    let combinedEffect = 1.0; // Start with 1 (no effect)
    
    for (const {re, mult} of this.intensifiers) {
      if (re.test(text)) {
        const signalEffect = Math.min(mult - 1, cap); // Cap the individual effect
        combinedEffect *= (1 - signalEffect); // Blend effects multiplicatively
      }
    }
    
    const finalBump = 1 - combinedEffect; // Convert back to additive bump
    
    // Scale by text length to prevent short texts from being over-boosted
    const lengthScale = Math.min(1.0, Math.log(text.length + 1) / Math.log(50)); // Scale smoothly up to 50 chars
    
    return Math.max(0, finalBump * lengthScale);
  }
  containsProfanity(text: string) { 
    const T = text.toLowerCase(); 
    // Use word boundaries to avoid false positives like "class" triggering "ass"
    const found = this.profanity.some(w => {
      // Create word boundary regex for each profanity word
      const regex = new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
      return regex.test(T);
    });
    logger.info(`Profanity check: text="${T}", profanityWords=[${this.profanity.slice(0, 5).join(', ')}...], found=${found}`);
    return found;
  }

  // Enhanced profanity detection with structured results
  analyzeProfanity(text: string): { 
    hasProfanity: boolean; 
    count: number; 
    matches: string[]; 
    hasTargetedSecondPerson: boolean;
    severity: 'mild' | 'moderate' | 'strong' | 'none';
  } {
    const T = text.toLowerCase();
    const matches: string[] = [];
    let maxSeverity: 'mild' | 'moderate' | 'strong' | 'none' = 'none';
    
    // Get profanity data with severity levels
    const prof = dataLoader.get('profanityLexicons');
    if (prof?.categories) {
      for (const category of prof.categories) {
        if (category.triggerWords && Array.isArray(category.triggerWords)) {
          for (const word of category.triggerWords) {
            const regex = new RegExp(`\\b${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
            if (regex.test(T)) {
              matches.push(word);
              // Track highest severity
              if (category.severity === 'strong') maxSeverity = 'strong';
              else if (category.severity === 'moderate' && maxSeverity !== 'strong') maxSeverity = 'moderate';
              else if (category.severity === 'mild' && maxSeverity === 'none') maxSeverity = 'mild';
            }
          }
        }
      }
    }

    // Check for second-person targeting
    const hasSecondPerson = /\byou(r|'re|re|)\b/.test(T);
    const hasTargetedSecondPerson = matches.length > 0 && hasSecondPerson;

    return {
      hasProfanity: matches.length > 0,
      count: matches.length,
      matches,
      hasTargetedSecondPerson,
      severity: maxSeverity
    };
  }
  getProfanityCount() { return this.profanity.length; }
}

const detectors = new ToneDetectors();

// -----------------------------
// Bucket mapping from JSON
// -----------------------------
function mapBucketsFromJson(
  toneLabel: string,
  contextKey: string,
  intensity: number,
  contextSeverity?: Record<Bucket, number>
): { primary: Bucket, dist: Record<Bucket, number>, meta: any } {
  const map = dataLoader.get('toneBucketMapping') || dataLoader.get('toneBucketMap');
  const base = map?.default?.[toneLabel] ?? map?.default?.neutral ?? { clear:0.33,caution:0.34,alert:0.33 };
  let dist = { ...base };

  const ctx = map?.contextOverrides?.[contextKey]?.[toneLabel];
  if (ctx) dist = { ...dist, ...ctx };

  const thr = map?.intensityShifts?.thresholds ?? { low:0.15, med:0.35, high:0.60 };
  const key = intensity >= thr.high ? 'high' : intensity >= thr.med ? 'med' : 'low';
  const shift = map?.intensityShifts?.[key] ?? {};
  
  // Apply intensity shifts to the distribution
  dist = {
    clear: Math.max(0,(dist.clear ?? 0)+(shift.clear ?? 0)),
    caution: Math.max(0,(dist.caution ?? 0)+(shift.caution ?? 0)),
    alert: Math.max(0,(dist.alert ?? 0)+(shift.alert ?? 0)),
  };

  // ✅ Apply context severity adjustments (new mechanism)
  if (contextSeverity) {
    logger.info('Applying context severity adjustments', contextSeverity);
    dist = {
      clear: Math.max(0, dist.clear + (contextSeverity.clear || 0)),
      caution: Math.max(0, dist.caution + (contextSeverity.caution || 0)),
      alert: Math.max(0, dist.alert + (contextSeverity.alert || 0)),
    };
  }

  const s = dist.clear + dist.caution + dist.alert || 1;
  const normalizedDist = { clear: dist.clear/s, caution: dist.caution/s, alert: dist.alert/s };
  const primary = (Object.entries(normalizedDist).sort((a,b)=>b[1]-a[1])[0][0]) as Bucket;
  return { primary, dist: normalizedDist, meta: { intensity, key, contextSeverity } };
}

// -----------------------------
// Realtime Tone Stream
// -----------------------------
export class ToneStream {
  private alpha = 0.6; // EWMA for token updates
  private lastDist: Record<Bucket, number> = { clear:1/3, caution:1/3, alert:1/3 };
  private tokens: string[] = [];
  private sentenceStart = 0;
  private buffer = '';
  private contextKey: string;
  private attachmentStyle: string;

  constructor(contextKey: string, attachmentStyle: string) {
    this.contextKey = contextKey;
    this.attachmentStyle = attachmentStyle;
  }

  feedChar(ch: string) {
    this.buffer += ch;
    if (/\s/.test(ch)) {
      const t = this.buffer.trim();
      if (t) this._fastToken(t);
      this.buffer = '';
    }
    if (/[.!?]/.test(ch)) {
      return this.finalizeSentence();
    }
    return null;
  }

  private _fastToken(token: string) {
    this.tokens.push(token);
    const win = this.tokens.slice(Math.max(0, this.tokens.length - 8));
    const hits = detectors.scanSurface(win);

    let log: Record<Bucket,number> = { clear:0,caution:0,alert:0 };
    for (const h of hits) log[h.bucket] += h.weight;

    const txt = win.join(' ');
    const bump = detectors.intensityBump(txt);
    log.alert += bump * 0.6; log.caution += bump * 0.2;

    // Guardrail: profanity instantly nudges toward alert
    const profanityCheck = detectors.analyzeProfanity(txt);
    if (profanityCheck.hasProfanity) { 
      // Scale alert boost by severity
      let alertBoost = 0.3;
      if (profanityCheck.severity === 'strong') alertBoost = 0.6;
      else if (profanityCheck.severity === 'moderate') alertBoost = 0.4;
      
      log.alert += alertBoost; 
      log.clear -= 0.1; 
    }

    // Optional clamp to avoid runaway
    const cap = 6.0;
    log.clear = Math.min(log.clear, cap);
    log.caution = Math.min(log.caution, cap);
    log.alert = Math.min(log.alert, cap);

    const dist = softmax3(log);
    this.lastDist = normalize3({
      clear: this.alpha*dist.clear + (1-this.alpha)*this.lastDist.clear,
      caution: this.alpha*dist.caution + (1-this.alpha)*this.lastDist.caution,
      alert: this.alpha*dist.alert + (1-this.alpha)*this.lastDist.alert,
    });
  }

  private finalizeSentence() {
    if (this.tokens.length === 0) return;
    const win = this.tokens.slice(Math.max(0, this.tokens.length - 8));
    const hits = detectors.scanSurface(win);

    let log: Record<Bucket,number> = { clear:0,caution:0,alert:0 };
    for (const h of hits) log[h.bucket] += h.weight;

    const txt = win.join(' ');
    const bump = detectors.intensityBump(txt);
    log.alert += bump * 0.6; log.caution += bump * 0.2;

    // Guardrail: profanity instantly nudges toward alert
    const profanityCheck = detectors.analyzeProfanity(txt);
    if (profanityCheck.hasProfanity) { 
      // Scale alert boost by severity
      let alertBoost = 0.3;
      if (profanityCheck.severity === 'strong') alertBoost = 0.6;
      else if (profanityCheck.severity === 'moderate') alertBoost = 0.4;
      
      log.alert += alertBoost; 
      log.clear -= 0.1; 
    }

    // Optional clamp to avoid runaway
    const cap = 6.0;
    log.clear = Math.min(log.clear, cap);
    log.caution = Math.min(log.caution, cap);
    log.alert = Math.min(log.alert, cap);

    const dist = softmax3(log);
    this.lastDist = normalize3({
      clear: this.alpha*dist.clear + (1-this.alpha)*this.lastDist.clear,
      caution: this.alpha*dist.caution + (1-this.alpha)*this.lastDist.caution,
      alert: this.alpha*dist.alert + (1-this.alpha)*this.lastDist.alert
    });

    this.tokens = [];
  }

  getCurrent() { return { ...this.lastDist }; }
}

export class ToneLiveController {
  private map = new Map<string, ToneStream>();
  get(fieldId: string, context='general', style='secure') {
    if (!this.map.has(fieldId)) this.map.set(fieldId, new ToneStream(context, style));
    return this.map.get(fieldId)!;
  }
  reset(fieldId: string) { this.map.delete(fieldId); }
}
export const toneLive = new ToneLiveController();

// -----------------------------
// Feature Extractor (JSON-aware)
// -----------------------------
class AdvancedFeatureExtractor {
  private emotionalLex: any;
  private attachmentHints: any;

  constructor() {
    this.emotionalLex = {
      anger: ['angry','mad','furious','frustrated','annoyed','irritated','pissed','livid','outraged'],
      sadness: ['sad','hurt','disappointed','upset','down','devastated','heartbroken'],
      anxiety: ['worried','anxious','nervous','scared','concerned','stressed','fearful','panicked'],
      joy: ['happy','excited','thrilled','delighted','joyful','glad','cheerful','ecstatic'],
      affection: ['love','adore','cherish','treasure','appreciate','care','affection','devoted']
    };
    this.attachmentHints = {
      secure: ['confident','trust','comfortable','open','balanced'],
      anxious: ['worried','need','please','afraid','insecure','clingy'],
      avoidant: ['fine','whatever','independent','space','alone']
    };
  }

  extract(text: string, attachmentStyle: string = 'secure', skipNegationFallback: boolean = false) {
    logger.info('Feature extraction started', { textLength: text.length, skipNegationFallback });
    const T = text.toLowerCase();
    const features: any = {};

    // emotions
    for (const [emo, list] of Object.entries(this.emotionalLex)) {
      let hits = 0; (list as string[]).forEach(k => { if (T.includes(k)) hits++; });
      features[`emo_${emo}`] = hits / Math.max(1, (list as string[]).length);
    }

    // simple counts
    const q = (text.match(/\?/g) || []).length; 
    const e = (text.match(/!/g) || []).length;
    features.int_q = q; features.int_exc = e;
    const caps = (text.match(/[A-Z]/g) || []).length; 
    const letters = (text.match(/[A-Za-z]/g) || []).length || 1;
    features.int_caps_ratio = caps / letters;
    features.int_elong = (text.match(/([a-z])\1{2,}/gi) || []).length;

    // intensity modifiers from JSON
    const intensityData = dataLoader.get('intensityModifiers');
    const mods = intensityData?.modifiers || [];
    let modScore = 0;
    mods.forEach((m: any) => { 
      if (m.pattern) { 
        try { 
          const r = new RegExp(m.pattern, 'i'); 
          if (r.test(text)) modScore += (m.multiplier || m.baseMultiplier || 1) - 1; 
        } catch {}
      } 
    });
    features.int_modscore = Math.max(0, modScore);

    // linguistics
    const S = text.split(/[.!?]+/).filter(s => s.trim().length > 0);
    features.lng_avgLen = S.length ? S.reduce((a, s) => a + s.length, 0) / S.length : 0;
    const first = [' i ',' me ',' my ',' mine ',' myself '];
    const second = [' you ',' your ',' yours ',' yourself '];
    const tpad = ` ${T} `;
    features.lng_first  = first.reduce((c, p) => c + (tpad.split(p).length - 1), 0);
    features.lng_second = second.reduce((c, p) => c + (tpad.split(p).length - 1), 0);
    features.lng_modal = (T.match(/\b(should|must|need to|have to|ought to)\b/g) || []).length;
    features.lng_absolutes = (T.match(/\b(always|never|every time)\b/g) || []).length;

    // attachment cues
    for (const [style, list] of Object.entries(this.attachmentHints)) {
      let hits = 0; (list as string[]).forEach(k => { if (T.includes(k)) hits++; });
      features[`attach_${style}`] = hits / Math.max(1, (list as string[]).length);
    }

    // negation/sarcasm regex fallback (only if spaCy won't handle it)
    if (!skipNegationFallback) {
      const neg = dataLoader.get('negationPatterns') || dataLoader.get('negationIndicators');
      const sar = dataLoader.get('sarcasmIndicators');
      
      logger.info('Negation data debug', { 
        neg: typeof neg, 
        negStructure: neg ? Object.keys(neg) : 'null',
        hasPatterns: neg?.patterns ? 'yes' : 'no',
        hasNegationIndicators: neg?.negation_indicators ? 'yes' : 'no',
        isArray: Array.isArray(neg),
        negSample: neg ? JSON.stringify(neg).substring(0, 200) : 'null'
      });
      
      // Fix: negation data is structured as { negation_indicators: [...] }
      const negationList = neg?.negation_indicators || neg?.patterns || neg || [];
      const sarcasmList = sar?.sarcasm_indicators || sar?.patterns || sar || [];
      
      const hasNeg = Array.isArray(negationList) && negationList.some((item: any) => {
        const pattern = item?.pattern || item;
        return typeof pattern === 'string' && new RegExp(pattern, 'i').test(text);
      });
      
      const hasSarc = Array.isArray(sarcasmList) && sarcasmList.some((item: any) => {
        const pattern = item?.pattern || item;
        return typeof pattern === 'string' && new RegExp(pattern, 'i').test(text);
      });
      features.neg_present = hasNeg ? 0.3 : 0;
      features.sarc_present = hasSarc ? 0.3 : 0;
    } else {
      // Will be set by spaCy results later
      features.neg_present = 0;
      features.sarc_present = 0;
      logger.info('Skipping negation/sarcasm fallback - will use spaCy results');
    }

    // phrase edges
    logger.info('Calling detectors.edgeHits');
    try {
      const edgeResults = detectors.edgeHits(text);
      logger.info('edgeHits completed', { resultCount: edgeResults.length });
      features.edge_hits = edgeResults.length; 
      features.edge_list = edgeResults;
    } catch (error) {
      logger.error('Error in detectors.edgeHits', {
        error: error,
        message: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
        name: error instanceof Error ? error.name : 'UnknownError',
        errorType: typeof error,
        errorString: String(error)
      });
      features.edge_hits = 0;
      features.edge_list = [];
    }

    logger.info('Feature extraction completed', { featureCount: Object.keys(features).length });
    return { features };
  }
}

// Reuse the detectors we already have:
function tokenizePlain(text: string): string[] {
  return text
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[^\w\s]/g,' ')
    .trim()
    .split(/\s+/)
    .filter(Boolean);
}

/** Collect raw phrase evidence per bucket from the whole text */
function collectBucketEvidence(text: string) {
  const tokens = tokenizePlain(text);
  const hits = detectors.scanSurface(tokens); // { bucket, weight, term, start, end }[]
  const byBucket = { clear: 0, caution: 0, alert: 0 } as Record<Bucket, number>;
  const termsByBucket: Record<Bucket, Set<string>> = { clear:new Set(), caution:new Set(), alert:new Set() };

  for (const h of hits) {
    byBucket[h.bucket] += Math.max(0, h.weight || 0);
    // term length in tokens (phrase-level check)
    const len = String(h.term || '').trim().split(/\s+/).filter(Boolean).length;
    if (len > 0) termsByBucket[h.bucket].add(`${h.term}__LEN${len}`);
  }
  return { byBucket, termsByBucket, tokens };
}

/** Whether clear evidence is only generic ("I/me/we/ok") or single-token fluff */
function clearIsOnlyGeneric(termsByBucket: Record<Bucket, Set<string>>): boolean {
  const entries = Array.from(termsByBucket.clear);
  if (entries.length === 0) return true;

  let hasSpecific = false;
  for (const tagged of entries) {
    const [term, lenTag] = tagged.split('__LEN');
    const len = parseInt(lenTag || '1', 10) || 1;
    const t = term.toLowerCase().trim();
    const isGeneric = GENERIC_CLEAR_STOPS.has(t);
    // require phrase-level (>= CLEAR_MIN_TOKENS) and not on the generic stop list
    if (len >= CLEAR_MIN_TOKENS && !isGeneric) {
      hasSpecific = true;
      break;
    }
  }
  return !hasSpecific;
}

/** Any escalatory contexts active? (by polarity) */
function hasEscalatoryContexts(activeContextIds: string[]): boolean {
  for (const id of activeContextIds) {
    const cfg = CTX_INDEX[id];
    if (cfg?.polarity === 'escalatory') return true;
  }
  return false;
}

/** Apply JSON bucket guards to a {clear,caution,alert} dist, using evidence + contexts. */
function enforceBucketGuards(
  dist: Record<Bucket, number>,
  evidence: ReturnType<typeof collectBucketEvidence>,
  activeContextIds: string[]
): Record<Bucket, number> {
  let { clear, caution, alert } = dist;

  // 1) Ignore generic/unigram "clear" evidence
  if (ENGINE?.genericTokens?.policy?.ignoreForBuckets?.clear) {
    if (clearIsOnlyGeneric(evidence.termsByBucket)) {
      clear = Math.min(clear, 0.01); // essentially zero without hard zeroing
    }
  }

  // 2) Escalatory presence dampens clear
  if (hasEscalatoryContexts(activeContextIds) && CLEAR_DAMPEN_ESCALATORY > 0 && clear > 0) {
    clear = clear * (1 - CLEAR_DAMPEN_ESCALATORY);
  }

  // 3) Overshadow rule: alert strong ⇒ clear must exceed ratio or be suppressed
  if ((CLEAR_OVERSHADOW?.bucket === 'alert') && alert >= (CLEAR_OVERSHADOW?.atOrAbove ?? 0.22)) {
    const need = alert * (CLEAR_OVERSHADOW?.ratioRequiredForClear ?? 1.75);
    if (clear < need) {
      // suppress clear rather than zeroing it completely
      clear = Math.min(clear, alert * 0.25);
    }
  }

  // 4) Prefer caution if both clear & alert noticeably present
  if (clear >= PREFER_CAUTION_IF_BOTH && alert >= PREFER_CAUTION_IF_BOTH) {
    const bleed = Math.min(0.15, clear * 0.25);
    clear -= bleed;
    caution += bleed; // move some to caution
  }

  // 5) Per-context clearGate (promote/dampen)
  if (Array.isArray(activeContextIds) && activeContextIds.length) {
    for (const id of activeContextIds) {
      const cfg = CTX_INDEX[id];
      const gate = cfg?.clearGate;
      if (!gate) continue;
      if (gate.mode === 'promote') {
        clear = clear + (clear * (gate.strength ?? 0.5));
      } else if (gate.mode === 'dampen') {
        clear = clear * (1 - (gate.strength ?? 0.5));
      }
    }
  }

  // Normalize
  const sum = Math.max(1e-9, clear + caution + alert);
  return { clear: clear/sum, caution: caution/sum, alert: alert/sum };
}

// -----------------------------
// Tone Analysis Service (JSON-weighted)
// -----------------------------
export class ToneAnalysisService {
  private fx = new AdvancedFeatureExtractor();

  constructor(private config: any = {}) {
    this.config = Object.assign({ 
      enableSmoothing: true, 
      enableSafetyChecks: true, 
      confidenceThreshold: 0.25 
    }, config);
    this.ensureDataLoaded();
  }

  private async ensureDataLoaded(): Promise<void> {
    // DataLoader is now pre-initialized synchronously
    if (!dataLoader.isInitialized()) {
      logger.warn('DataLoader not initialized in ToneAnalysisService');
    }
  }

  private _weights(context: string) {
    const W = {
      emo: 0.40, ctx: 0.20, attach: 0.15, ling: 0.15, intensity: 0.10,
      negPenalty: 0.15, sarcPenalty: 0.18, absolutesBoost: 0.06
    };
    const mods = dataLoader.get('weightModifiers')?.byContext?.[context];
    if (mods) {
      // Allow additive overrides for transparency/simplicity
      for (const [k,v] of Object.entries(mods)) {
        if ((W as any)[k] !== undefined && typeof v === 'number') {
          (W as any)[k] = (W as any)[k] + v;
        }
      }
    }
    return W;
  }

  private _scoreTones(fr: any, text: string, attachmentStyle: string, contextHint: string) {
    const f = fr.features || {};
    const W = this._weights(contextHint);
    const out: any = { 
      neutral: 0.1, positive: 0.1, supportive: 0.1, 
      anxious: 0, angry: 0, frustrated: 0, sad: 0, assertive: 0 
    };

    // Enhanced profanity analysis (single call, structured result)
    const profanityAnalysis = detectors.analyzeProfanity(text);

    // ✅ Enhanced context detection with smart schema
    const tokens = text.toLowerCase().split(/\s+/).filter(Boolean);
    const contextDetection = detectors.detectContexts(tokens, attachmentStyle);
    
    logger.info('Enhanced context detection', { 
      primaryContext: contextDetection.primaryContext,
      allContexts: contextDetection.allContexts.length,
      deescalated: contextDetection.deescalated
    });

    // Get context multipliers and attachment bias from enhanced tone_triggerwords.json
    const triggerWordsData = dataLoader.get('toneTriggerWords') || dataLoader.get('toneTriggerwords');
    const contextMultipliers = triggerWordsData?.weights?.contextMultipliers?.[contextHint] || {};
    const attachmentBias = triggerWordsData?.weights?.attachmentBias?.[attachmentStyle] || {};

    logger.info('_scoreTones called', { text: text.substring(0, 50), attachmentStyle, contextHint });
    logger.info('Features available', { edgeList: f.edge_list, emoAnger: f.emo_anger, lngAbsolutes: f.lng_absolutes });
    logger.info('Profanity analysis', profanityAnalysis);
    logger.info('Context multipliers loaded', { contextHint, multipliers: Object.keys(contextMultipliers).length });
    logger.info('Attachment bias loaded', { attachmentStyle, biases: Object.keys(attachmentBias).length });

    // Emotion-driven
    out.angry      += (f.emo_anger || 0) * W.emo;
    out.sad        += (f.emo_sadness || 0) * W.emo;
    out.anxious    += (f.emo_anxiety || 0) * W.emo;
    out.positive   += (f.emo_joy || 0) * (W.emo * 0.9);
    out.supportive += (f.emo_affection || 0) * (W.emo * 0.9);

    // ✅ Apply enhanced context boosts and severity adjustments
    for (const contextResult of contextDetection.allContexts) {
      // Apply confidence boosts (original mechanism)
      for (const [bucket, boost] of Object.entries(contextResult.boosts)) {
        if (bucket === 'clear') {
          out.supportive += boost * contextResult.confidence;
          out.positive += boost * contextResult.confidence * 0.8;
        } else if (bucket === 'caution') {
          out.anxious += boost * contextResult.confidence;
          out.frustrated += boost * contextResult.confidence * 0.7;
        } else if (bucket === 'alert') {
          out.angry += boost * contextResult.confidence;
          out.frustrated += boost * contextResult.confidence * 0.6;
        }
      }
      
      // Apply severity adjustments (new mechanism for direct bucket impact)
      // These will be applied later when computing bucket distributions
      fr.contextSeverity = fr.contextSeverity || { clear: 0, caution: 0, alert: 0 };
      for (const [bucket, severity] of Object.entries(contextResult.severity)) {
        fr.contextSeverity[bucket] += severity * contextResult.confidence;
      }
    }

    // Apply deescalation effects
    let deescalationFactor = 1.0;
    if (contextDetection.deescalated.length > 0) {
      deescalationFactor = 0.7; // Reduce aggressive tones when deescalated
      logger.info('Deescalation applied', { deescalated: contextDetection.deescalated });
    }

    // Context cues with enhanced multipliers
    const ctx = contextDetection.primaryContext || (contextHint || 'general').toLowerCase();
    if (ctx.includes('conflict') || ctx.includes('escalation')) { 
      out.angry += 0.25 * (contextMultipliers.escalation || 1.0) * deescalationFactor; 
      out.frustrated += 0.20 * (contextMultipliers.contempt || 1.0) * deescalationFactor; 
    }
    if (ctx.includes('planning')) { 
      out.assertive += 0.12 * (contextMultipliers.structure || 1.0); 
      out.neutral += 0.08 * (contextMultipliers.plan || 1.0); 
    }
    if (ctx.includes('repair')) { 
      out.supportive += 0.18 * (contextMultipliers.solution || 1.0); 
    }
    if (ctx.includes('humor')) {
      // Humor context significantly reduces aggressive tones
      out.angry *= 0.3;
      out.frustrated *= 0.5;
      out.positive += 0.15;
    }

    // Linguistic (absolutes & modals tilt toward confront/defend)
    const absolutesMultiplier = contextMultipliers.escalation || 1.0;
    out.angry += Math.min(0.25, (f.lng_absolutes || 0) * (W.absolutesBoost ?? 0.06) * absolutesMultiplier);
    out.assertive += Math.min(0.20, (f.lng_modal || 0) * 0.03);

    // Enhanced attachment adjustments with bias from JSON
    if (attachmentStyle === 'anxious') { 
      out.anxious += (f.attach_anxious || 0) * 0.35 * (attachmentBias.uncertainty || 1.0); 
    }
    if (attachmentStyle === 'avoidant') { 
      out.frustrated += (f.attach_avoidant || 0) * 0.25 * (attachmentBias.avoidance || 1.0); 
    }
    if (attachmentStyle === 'secure') { 
      out.supportive += (f.attach_secure || 0) * 0.25 * (attachmentBias.solution || 1.0); 
    }

    // Intensity (punctuation, caps, elongation, modifiers)
    const intensity = clamp01(
      (f.int_q || 0) * 0.05 + 
      (f.int_exc || 0) * 0.08 + 
      (f.int_caps_ratio || 0) * 0.8 + 
      (f.int_elong || 0) * 0.08 + 
      (f.int_modscore || 0)
    );
    out.angry      += intensity * (0.35 + (W.intensity ?? 0)*0.1); 
    out.frustrated += intensity * 0.25; 
    out.supportive -= intensity * 0.05;

    // Negation/sarcasm penalties
    const neg = f.neg_present || 0;
    const sar = f.sarc_present || 0;
    out.supportive -= sar * (W.sarcPenalty ?? 0.18); 
    out.positive   -= sar * ((W.sarcPenalty ?? 0.18) * 0.6);
    out.angry      += sar * 0.12; 
    out.frustrated += sar * 0.10;
    out.angry      += neg * (0.10 + (W.negPenalty ?? 0.15)*0.05); 
    out.frustrated += neg * 0.08; 
    out.neutral    -= neg * 0.05;

    // Phrase edges (rupture/repair) with weights and context multipliers
    const edgeResults = Array.isArray(f.edge_list) ? f.edge_list : [];
    for (const edge of edgeResults) {
      const weight = typeof edge === 'object' ? edge.weight : 1;
      const category = typeof edge === 'object' ? edge.cat : edge;
      if (category === 'rupture') { 
        out.angry += 0.25 * weight * (contextMultipliers.escalation || 1.0); 
        out.frustrated += 0.15 * weight * (contextMultipliers.contempt || 1.0); 
      }
      if (category === 'repair') { 
        out.supportive += 0.22 * weight * (contextMultipliers.solution || 1.0); 
      }
    }

    // Enhanced profanity handling with severity levels and context multipliers
    if (profanityAnalysis.hasProfanity) {
      let profanityWeight = 0.2; // base weight
      
      // Scale by severity
      switch (profanityAnalysis.severity) {
        case 'mild': profanityWeight = 0.1; break;
        case 'moderate': profanityWeight = 0.2; break;
        case 'strong': profanityWeight = 0.4; break;
      }
      
      // Apply context multipliers for profanity
      profanityWeight *= (contextMultipliers.profanity || 1.0);
      
      // Scale by count (with diminishing returns)
      const countMultiplier = Math.min(2.0, 1 + Math.log(profanityAnalysis.count) * 0.3);
      profanityWeight *= countMultiplier;
      
      out.angry += profanityWeight;
      out.supportive = Math.max(0, out.supportive - profanityWeight * 0.5);
      
      // Store profanity analysis for hard-floor check later
      fr.profanityAnalysis = profanityAnalysis;
    }

    for (const k of Object.keys(out)) out[k] = Math.max(0, out[k]);
    return { scores: out, intensity };
  }

  private _softmaxScores(scores: any) {
    const vals = Object.values(scores) as number[];
    const max = Math.max(...vals, 0);
    const exps: any = {}; let sum = 0;
    for (const [k, v] of Object.entries(scores)) { const e = Math.exp((v as number) - max); exps[k] = e; sum += e; }
    const dist: any = {}; 
    for (const [k, e] of Object.entries(exps)) dist[k] = (e as number) / (sum || 1);
    return dist;
  }

  private _primaryFromDist(dist: any) {
    return Object.entries(dist).sort((a: any, b: any) => b[1] - a[1])[0][0];
  }

  private _safety(text: string): boolean {
    const g = dataLoader.get('guardrailConfig');
    const t = text.toLowerCase();
    const kw: string[] = g?.selfHarmKeywords ?? ['kill','die','suicide','hurt myself','end it all','harm'];
    return kw.some(k => t.includes(k));
  }

  private _formality(text: string): number {
    const formal = ['please','thank you','regards','sincerely','furthermore','however'];
    const informal = ['gonna','wanna','hey','yeah','lol','omg'];
    const T = text.toLowerCase();
    const f = formal.reduce((n,w)=>n+(T.includes(w)?1:0),0);
    const i = informal.reduce((n,w)=>n+(T.includes(w)?1:0),0);
    if (!f && !i) return 0.5;
    return f / (f+i);
  }

  private _empathyIndicators(text: string): string[] {
    const indicators = [
      { pattern: /\bi understand\b/i, indicator: 'understanding acknowledgment' },
      { pattern: /\bi can see\b/i, indicator: 'perspective taking' },
      { pattern: /\bthat must be\b/i, indicator: 'emotional validation' },
      { pattern: /\bi hear you\b/i, indicator: 'active listening' },
      { pattern: /\bi appreciate\b/i, indicator: 'gratitude expression' },
      { pattern: /\bmakes sense\b/i, indicator: 'validation' },
    ];
    return indicators.filter(i => i.pattern.test(text)).map(i => i.indicator);
  }

  private _misunderstandings(text: string): string[] {
    const issues = [
      { pattern: /\byou always\b/i, issue: 'absolute language may trigger defensiveness' },
      { pattern: /\byou never\b/i, issue: 'absolute language may trigger defensiveness' },
      { pattern: /\bobviously\b/i, issue: 'may sound condescending' },
      { pattern: /\bwhatever\b/i, issue: 'dismissive tone' },
      { pattern: /\bfine\b(?!\s+(with|by))/i, issue: 'may indicate passive aggression' },
      { pattern: /\bshould have\b/i, issue: 'may sound judgmental' },
    ];
    return issues.filter(i => i.pattern.test(text)).map(i => i.issue);
  }

  private _detectPrimaryToneHeuristic(text: string): string {
    const T = text.toLowerCase();
    if (T.includes('love') || T.includes('appreciate') || T.includes('grateful')) return 'positive';
    if (T.includes('hate') || T.includes('angry') || T.includes('frustrated')) return 'negative';
    if (T.includes('?') || T.includes('maybe') || T.includes('perhaps')) return 'tentative';
    if (T.includes('!') || T.includes('definitely') || T.includes('absolutely')) return 'confident';
    return 'neutral';
  }

  async analyzeAdvancedTone(text: string, options: ToneAnalysisOptions = { context: 'general' }): Promise<AdvancedToneResult> {
    try {
      logger.info('Starting advanced tone analysis', { text: text.substring(0, 50), options });
      this.ensureDataLoaded();

      const style = options.attachmentStyle || 'secure';
      logger.info('Using attachment style', { style });

      // Use spaCy bridge with reliability features
      logger.info('Calling spacyLite');
      const doc = await spacyLite(text, options.context);
      logger.info('spacyLite completed', { tokens: doc.tokens.length, contextLabel: doc.contextLabel });

      // Extract features (skip negation fallback since spaCy will provide it)
      logger.info('Extracting features');
      const fr = this.fx.extract(text, style, true); // skipNegationFallback = true
      logger.info('Features extracted', { featureCount: Object.keys(fr.features).length });
      
      // Replace naive neg/sarc with spaCy scoped values
      fr.features.neg_present = doc.negScopes.length > 0 ? 0.3 : 0;
      fr.features.sarc_present = doc.sarcasmCue ? 0.3 : 0;

      // POS-aware intensity facets
      const advBump = doc.tokens.filter(t => t.pos === 'ADV').length * 0.04;
      const excl = (text.match(/!/g)||[]).length * 0.08;
      const q = (text.match(/\?/g)||[]).length * 0.04;
      const caps = (text.match(/[A-Z]{2,}/g)||[]).length * 0.12;

      // Score
      logger.info('Scoring tones');
      const { scores, intensity: baseIntensity } = this._scoreTones(fr, text, style, doc.contextLabel || options.context || 'general');
      const intensity = clamp01(baseIntensity + advBump + excl + q + caps);
      
      // 🔒 Hard-floor: profanity + 2nd-person targeting => angry
      const T = text.toLowerCase();
      const secondPerson = /\byou(r|'re|re|)\b/.test(T) || (fr.features?.lng_second ?? 0) > 0;
      
      // Use enhanced profanity analysis from scoring
      const profanityAnalysis = (fr as any).profanityAnalysis || detectors.analyzeProfanity(text);
      
      logger.info(`Hard-floor check: text="${text}", hasProfanity=${profanityAnalysis.hasProfanity}, hasTargetedSecondPerson=${profanityAnalysis.hasTargetedSecondPerson}, severity=${profanityAnalysis.severity}, matches=${profanityAnalysis.matches.join(',')}`);
      
      // Enhanced hard-floor with severity consideration  
      // Trigger for: targeted profanity, OR moderate/strong profanity + 2nd-person, OR strong profanity alone
      if (profanityAnalysis.hasTargetedSecondPerson || 
          (profanityAnalysis.hasProfanity && (profanityAnalysis.severity === 'strong' || profanityAnalysis.severity === 'moderate') && secondPerson) ||
          (profanityAnalysis.hasProfanity && profanityAnalysis.severity === 'strong')) {
        
        const triggerReason = profanityAnalysis.hasTargetedSecondPerson ? 'targeted profanity' : 
                            profanityAnalysis.severity === 'strong' ? 'strong profanity' : 
                            'moderate profanity + 2nd-person';
        logger.info(`🔒 HARD-FLOOR TRIGGERED: ${triggerReason} => forcing angry tone`);
        
        // Scale intervention by severity
        let angerBoost = 1.2;
        let supportivePenalty = 0.5;
        let positivePenalty = 0.4;
        
        if (profanityAnalysis.severity === 'strong') {
          angerBoost = 1.5;
          supportivePenalty = 0.7;
          positivePenalty = 0.6;
        } else if (profanityAnalysis.severity === 'moderate') {
          angerBoost = 1.0;  // Still significant boost for moderate + targeting
          supportivePenalty = 0.4;
          positivePenalty = 0.3;
        }
        
        scores.angry = Math.max(scores.angry ?? 0, angerBoost);
        scores.supportive = Math.max(0, (scores.supportive ?? 0) - supportivePenalty);
        scores.positive   = Math.max(0, (scores.positive   ?? 0) - positivePenalty);
      }
      
      logger.info('Tones scored', { scores, intensity });

      // Softmax
      const distribution = this._softmaxScores(scores);
      let classification = this._primaryFromDist(distribution);
      let confidence = distribution[classification] || 0.33;
      
      // Override for profanity + 2nd-person targeting or strong profanity
      if (profanityAnalysis.hasTargetedSecondPerson || 
          (profanityAnalysis.hasProfanity && (profanityAnalysis.severity === 'strong' || profanityAnalysis.severity === 'moderate') && secondPerson) ||
          (profanityAnalysis.hasProfanity && profanityAnalysis.severity === 'strong')) {
        classification = 'angry';
        confidence = Math.max(confidence, 0.75);
      }
      
      logger.info('Classification computed', { classification, confidence, distribution });

      // Guardrail: safety override
      if (this.config.enableSafetyChecks && this._safety(text)) {
        classification = 'safety_concern';
        confidence = Math.max(confidence, 0.95);
      }

      // LearningSignals: nudge thresholds (e.g., reduce false "positive" in conflict)
      const ls = dataLoader.get('learningSignals');
      const ctxAdj = ls?.toneBias?.[(doc.contextLabel || options.context || 'general')];
      if (ctxAdj?.[classification] !== undefined) {
        confidence = clamp01(confidence + ctxAdj[classification]);
      }

      // Confidence calibration (Platt + learningSignals adjustment)
      confidence = plattCalibrate(confidence, doc.contextLabel || options.context || 'general');

      // Adjust for new users: reduce confidence to encourage learning
      if (options.isNewUser) {
        confidence = Math.max(0.1, confidence * 0.7); // Reduce confidence by 30% for new users
      }

      // Apply semantic backbone nudges (optional feature)
      const nudgedResult = applySemanticBackboneNudges(
        text,
        { classification, confidence },
        doc.contextLabel || options.context || 'general'
      );
      classification = nudgedResult.tone.classification;
      confidence = nudgedResult.tone.confidence;
      const adjustedContextLabel = nudgedResult.contextLabel;

      // Pack result
      const emotions = {
        joy: scores.positive || 0,
        anger: scores.angry || 0,
        fear: scores.anxious || 0,
        sadness: scores.sad || 0,
        analytical: scores.assertive || 0,
        confident: scores.supportive || 0,
        tentative: scores.neutral || 0
      };

      const sentiment_score = clamp01((emotions.joy + emotions.confident) - (emotions.anger + emotions.sadness + emotions.fear));

      const result: AdvancedToneResult = {
        primary_tone: classification,
        confidence,
        emotions,
        intensity,
        sentiment_score,
        linguistic_features: {
          formality_level: this._formality(text),
          emotional_complexity: Object.values(emotions).filter(v => v > 0.1).length / 7,
          assertiveness: emotions.analytical,
          empathy_indicators: this._empathyIndicators(text),
          potential_misunderstandings: this._misunderstandings(text),
        },
        context_analysis: {
          appropriateness_score: Math.max(0, 1 - emotions.anger - emotions.fear),
          relationship_impact: sentiment_score > 0.2 ? 'positive' : sentiment_score < -0.2 ? 'negative' : 'neutral',
          suggested_adjustments: emotions.anger > 0.4 ? ['Consider softening the tone'] : []
        },
      };

      // ✅ Add context severity for bucket mapping
      (result as any).contextSeverity = (fr as any).contextSeverity;

      // Add semantic backbone debug info if enabled
      if (ENABLE_SB && nudgedResult.debug) {
        (result as any).semanticBackbone = nudgedResult.debug;
      }

      if (options.includeAttachmentInsights) {
        result.attachment_insights = {
          likely_attachment_response: style,
          triggered_patterns: emotions.fear > 0.4 ? ['anxiety triggers detected'] : [],
          healing_suggestions: emotions.confident > 0.3 ? ['Continue supportive communication'] : []
        };
      }

      return result;
    } catch (err) {
      logger.error('Advanced tone analysis failed:', {
        error: err,
        message: err instanceof Error ? err.message : String(err),
        stack: err instanceof Error ? err.stack : undefined,
        name: err instanceof Error ? err.name : 'UnknownError',
        errorType: typeof err,
        errorString: String(err)
      });
      // no LLM fallback; return neutral minimal result
      return {
        primary_tone: 'neutral',
        confidence: 0.3,
        emotions: { joy:0, anger:0, fear:0, sadness:0, analytical:0, confident:0, tentative:0.3 },
        intensity: 0.3,
        sentiment_score: 0,
        linguistic_features: {
          formality_level: 0.5,
          emotional_complexity: 0.3,
          assertiveness: 0.3,
          empathy_indicators: [],
          potential_misunderstandings: ['Analysis failed - using fallback']
        },
        context_analysis: {
          appropriateness_score: 0.5,
          relationship_impact: 'neutral',
          suggested_adjustments: ['Try again with different text']
        }
      };
    }
  }
}

export const toneAnalysisService = new ToneAnalysisService();

// -----------------------------
// Compatibility exports (JS parity)
// -----------------------------
export function loadAllData(baseDir?: string): any {
  return {
    contextClassifier: dataLoader.get('contextClassifier'),
    toneTriggerwords: dataLoader.get('toneTriggerWords') || dataLoader.get('toneTriggerwords'),
    intensityModifiers: dataLoader.get('intensityModifiers'),
    sarcasmIndicators: dataLoader.get('sarcasmIndicators'),
    negationIndicators: dataLoader.get('negationIndicators') || dataLoader.get('negationPatterns'),
    phraseEdges: dataLoader.get('phraseEdges'),
    semanticThesaurus: dataLoader.get('semanticThesaurus'),
    toneBucketMap: dataLoader.get('toneBucketMapping') || dataLoader.get('toneBucketMap'),
    // meta sets exposed too
    weightModifiers: dataLoader.get('weightModifiers'),
    guardrailConfig: dataLoader.get('guardrailConfig'),
    profanityLexicons: dataLoader.get('profanityLexicons'),
    learningSignals: dataLoader.get('learningSignals'),
    evaluationTones: dataLoader.get('evaluationTones'),
  };
}

export function mapToneToBuckets(
  toneResult: any, 
  attachmentStyle: string = 'secure', 
  contextKey: string = 'default', 
  data: any = null, 
  config: any = {}
): any {
  if (!data) {
    data = loadAllData(config.dataDir);
  }
  
  const bucketMap = data.toneBucketMapping || data.toneBucketMap || {};
  const defaultBuckets = bucketMap.toneBuckets || bucketMap.default || {};
  const contextOverrides = bucketMap.contextOverrides || {};
  const intensityShifts = bucketMap.intensityShifts || {};
  
  const tone = toneResult.classification || toneResult.tone?.classification || toneResult.primary_tone || 'neutral';
  const confidence = toneResult.confidence || toneResult.tone?.confidence || 0.5;
  
  logger.info('mapToneToBuckets debug', { 
    tone, 
    confidence, 
    bucketMapKeys: Object.keys(bucketMap),
    defaultBucketsKeys: Object.keys(defaultBuckets),
    hasAngryMapping: !!defaultBuckets.angry
  });
  
  // Get base bucket probabilities with fallback
  let buckets = { clear: 0.5, caution: 0.3, alert: 0.2 }; // neutral fallback
  if (defaultBuckets[tone]?.base) {
    buckets = { ...defaultBuckets[tone].base };
    logger.info('Found bucket mapping for tone', { tone, buckets });
  } else {
    logger.warn('No bucket mapping found for tone, using neutral fallback', { tone, availableTones: Object.keys(defaultBuckets) });
  }
  
  // Apply context overrides if available
  if (contextOverrides[contextKey] && contextOverrides[contextKey][tone]) {
    buckets = { ...buckets, ...contextOverrides[contextKey][tone] };
  }
  
  // Apply intensity shifts based on confidence (proxy)
  const thresholds = intensityShifts.thresholds || { low: 0.15, med: 0.35, high: 0.60 };
  let intensityLevel: 'low'|'med'|'high' = 'med';
  if (confidence < thresholds.low) intensityLevel = 'low';
  else if (confidence > thresholds.high) intensityLevel = 'high';
  
  const shifts = intensityShifts[intensityLevel] || {};
  for (const [bucket, shift] of Object.entries(shifts)) {
    if ((buckets as any)[bucket] !== undefined) {
      (buckets as any)[bucket] = Math.max(0, Math.min(1, (buckets as any)[bucket] + (shift as number)));
    }
  }
  
  // Normalize
  const total = Object.values(buckets).reduce((sum, val) => sum + (val as number), 0);
  if (total > 0) {
    (['clear','caution','alert'] as Bucket[]).forEach(b => (buckets as any)[b] = (buckets as any)[b] / total);
  }

  // ✅ NEW: optional guard application if caller passed { text }
  if (config?.text && ENGINE) {
    const evidence = collectBucketEvidence(String(config.text || ''));
    // derive contexts from text so we can apply clearGate/overshadow
    const ctxDetected = detectors.detectContexts(tokenizePlain(String(config.text || '')), attachmentStyle);
    const activeIds = (ctxDetected.allContexts || []).map((c:any) => c.id);
    buckets = enforceBucketGuards(buckets, evidence, activeIds);
  }
  
  return {
    buckets,
    metadata: { tone, confidence, attachmentStyle, contextKey, intensityLevel }
  };
}

export function createToneAnalyzer(config: any = {}): any {
  const {
    premium = false,
    confidenceThreshold = 0.25,
    dataDir,
    enableSmoothing = true,
    smoothingAlpha = 0.7,
    hysteresisThreshold = 0.2,
    decayRate = 0.95
  } = config;

  const tier = premium ? 'premium' : 'general';
  const data = loadAllData(dataDir);

  return {
    async analyzeTone(text: string, attachmentStyle: string = 'secure', contextHint: string = 'general') {
      const result = await toneAnalysisService.analyzeAdvancedTone(text, {
        context: contextHint,
        attachmentStyle,
        includeAttachmentInsights: premium
      });
      return {
        success: true,
        tone: { classification: result.primary_tone, confidence: result.confidence },
        emotions: result.emotions,
        intensity: result.intensity,
        metadata: { attachmentStyle, context: contextHint, tier, timestamp: new Date().toISOString() }
      };
    },
    mapToneToBuckets(toneResult: any, attachmentStyle: string = 'secure', contextKey: string = 'default') {
      return mapToneToBuckets(toneResult, attachmentStyle, contextKey, data, config);
    },
    getConfig() { return { ...config, tier }; },
    updateConfig(newConfig: any) { Object.assign(config, newConfig); return this; }
  };
}

// -----------------------------
// Quick analysis function for testing (compatibility)
// -----------------------------
export async function getGeneralToneAnalysis(text: string, attachmentStyle: string = 'secure', context: string = 'general'): Promise<any> {
  try {
    const result = await toneAnalysisService.analyzeAdvancedTone(text, {
      context,
      attachmentStyle,
      includeAttachmentInsights: false
    });
    
    const bucketResult = mapBucketsFromJson(result.primary_tone, context, result.intensity, (result as any).contextSeverity);
    
    // NEW: enforce engine guards using real evidence + actual active contexts
    const evidence = collectBucketEvidence(text);
    const ctxTokens = tokenizePlain(text);
    const ctxDetected = detectors.detectContexts(ctxTokens, attachmentStyle);
    const activeIds = (ctxDetected.allContexts || []).map(c => c.id);

    const guardedDist = enforceBucketGuards(bucketResult.dist, evidence, activeIds);
    const primaryBucket = (Object.entries(guardedDist).sort((a,b)=>b[1]-a[1])[0][0]) as Bucket;
    
    return {
      tone: result.primary_tone,
      confidence: result.confidence,
      buckets: guardedDist,               // <-- use guarded
      primary_bucket: primaryBucket,      // <-- use guarded
      intensity: result.intensity,
      emotions: result.emotions,
      linguistic_features: result.linguistic_features,
      context_analysis: result.context_analysis,
      metadata: { attachmentStyle, context, timestamp: new Date().toISOString() }
    };
  } catch (error: any) {
    logger.error('General tone analysis failed:', error);
    return {
      tone: 'neutral',
      confidence: 0.3,
      buckets: { clear: 0.5, caution: 0.3, alert: 0.2 },
      primary_bucket: 'clear',
      intensity: 0.3,
      error: error?.message || 'Analysis failed'
    };
  }
}

// -----------------------------
// MLAdvancedToneAnalyzer (compat shim)
// -----------------------------
export class MLAdvancedToneAnalyzer {
  private cfg: any;
  constructor(config: any = {}) { this.cfg = config; }
  async analyzeTone(text: string, attachmentStyle: string = 'secure', contextHint: string = 'general', tier: string = 'general') {
    try {
      const res = await toneAnalysisService.analyzeAdvancedTone(text, {
        context: contextHint,
        attachmentStyle,
        includeAttachmentInsights: tier === 'premium'
      });
      return {
        success: true,
        tone: { classification: res.primary_tone, confidence: res.confidence },
        scores: res.emotions,
        distribution: res.emotions,
        features: { count: Object.keys(res.linguistic_features || {}).length, bundle: res.linguistic_features },
        metadata: { attachmentStyle, context: contextHint, tier, timestamp: new Date().toISOString() }
      };
    } catch (error:any) {
      logger.error('Tone analysis error', error);
      return { success: false, tone: { classification: 'neutral', confidence: 0.1, error: error?.message || 'Unknown' } };
    }
  }
}
