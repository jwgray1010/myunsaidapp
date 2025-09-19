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

// === Profanity helpers (inline, v1.3.1) =====================================
type ProfSeverity = 'mild'|'moderate'|'strong';
type ProfHit = {
  term: string;
  severity: ProfSeverity;
  start: number;
  end: number;
  partialMatch?: boolean;
  targetedSecondPerson?: boolean;
};

// Conversational context memory for micro-awareness
interface ConversationMemory {
  lastTone: Bucket | null;
  lastTimestamp: number;
  lastSecondPersonCount: number;
  lastAddressee: string | null;
}

// Global conversation memory map
const conversationMemory = new Map<string, ConversationMemory>();

// Fix #6: Reset conversation memory for testing isolation
export function resetConversationMemory(fieldId?: string): void {
  if (fieldId) {
    conversationMemory.delete(fieldId);
    logger.info(`🧹 Conversation memory reset for field: ${fieldId}`);
  } else {
    conversationMemory.clear();
    logger.info('🧹 All conversation memory cleared for testing');
  }
}

// Tolerant normalization for masked swears and unicode weirdness
function normalizeForProfanity(raw: string): string {
  let s = raw.normalize('NFKC').toLowerCase();
  s = s.replace(/\s+/g, ' ').trim();
  
  // Enhanced homoglyph and leetspeak normalization
  const HOMOGLYPH_MAP: Record<string, string> = {
    '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't',
    '@': 'a', '$': 's', '!': 'i', '|': 'l'
  };
  
  for (const [glyph, replacement] of Object.entries(HOMOGLYPH_MAP)) {
    s = s.replace(new RegExp(glyph, 'g'), replacement);
  }
  
  // collapse extreme elongations: fuuuuuck -> fff
  s = s.replace(/(.)\1{3,}/g, '$1$1$1');
  // light diacritic strip (ASCII fold) — safe enough for our words
  try { s = s.normalize('NFD').replace(/[\u0300-\u036f]/g, ''); } catch {}
  // common masked forms
  const map: Record<string,string> = {
    'f*ck':'fuck','f**k':'fuck','f#ck':'fuck','f@ck':'fuck','f-ck':'fuck','f—ck':'fuck',
    "f'ing":"fucking","effing":"fucking","fkn":"fucking",
    'sh*t':'shit','bi*ch':'bitch','a**hole':'asshole','d*ck':'dick'
  };
  for (const [k,v] of Object.entries(map)) {
    const safe = k.replace(/[-/\\^$+?.()|[\]{}]/g, '\\$&').replace(/\*/g, '.?');
    s = s.replace(new RegExp(safe, 'g'), v);
  }
  return s;
}

// Fallback control (env kill switch)
const DISABLE_WEIGHT_FALLBACKS = process.env.DISABLE_WEIGHT_FALLBACKS === '1';

// Optional: log each fallback hit
const WEIGHTS_FALLBACK_EVENT = 'weights.fallback';

// Pull maps from JSON at runtime
function getWeightMods() { return dataLoader.get('weightModifiers'); }

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
  metaClassifier?: {
    pAlert: number;
    pCaution: number;
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

type ResolvedContext = { key: string; reason: string };

function resolveContextKey(rawCtx: string): ResolvedContext {
  const wm = getWeightMods();
  const ctx = (rawCtx || 'general').toLowerCase().trim();

  // Guard: no config or kill switch
  if (!wm || DISABLE_WEIGHT_FALLBACKS) {
    return { key: ctx, reason: wm ? 'nofallbacks_env' : 'nofallbacks_missing_config' };
  }

  const byContext = wm.byContext || {};
  const aliasMap = wm.aliasMap || {};
  const familyMap = wm.familyMap || {};
  const fallbacks = wm.fallbacks || { order: ['exact','general','code_default'], enabled: true };

  // 1) exact
  if (byContext[ctx]) return { key: ctx, reason: 'exact' };

  // 2) alias
  const aliased = aliasMap[ctx];
  if (aliased && byContext[aliased]) return { key: aliased, reason: `alias:${ctx}` };

  // 3) family (e.g., CTX_CONFLICT → conflict)
  const fam = familyMap[ctx];
  if (fam && byContext[fam]) return { key: fam, reason: `family:${ctx}` };

  // 4) general
  if (byContext.general) return { key: 'general', reason: `fallback:general(${ctx})` };

  // 5) code_default (no JSON deltas)
  return { key: '__code_default__', reason: `fallback:code_default(${ctx})` };
}

// ===== Tone Bucket Mapping helpers (v2.1.1) =====
function normBuckets(d: Record<Bucket, number>): Record<Bucket, number> {
  const s = Math.max(1e-9, (d.clear||0)+(d.caution||0)+(d.alert||0));
  return { clear: (d.clear||0)/s, caution: (d.caution||0)/s, alert: (d.alert||0)/s };
}
function logit(p:number){ const e=1e-6; const q=Math.min(1-e,Math.max(e,p)); return Math.log(q/(1-q)); }
function ilogit(z:number){ return 1/(1+Math.exp(-z)); }

function tokenizePlainV2(text: string): string[] {
  return text.normalize('NFKC').toLowerCase().replace(/[^\w\s]/g,' ')
    .trim().split(/\s+/).filter(Boolean);
}

/** Collect raw phrase evidence per bucket from the whole text using existing detectors */
function collectBucketEvidenceV2(text: string) {
  const tokens = tokenizePlainV2(text);
  const hits = detectors.scanSurface(tokens); // { bucket, weight, term, start, end }[]
  const byBucket: Record<Bucket, number> = { clear:0, caution:0, alert:0 };
  const termsByBucket: Record<Bucket, Set<string>> = { clear:new Set(), caution:new Set(), alert:new Set() };
  for (const h of hits) {
    byBucket[h.bucket] += Math.max(0, h.weight || 0);
    const len = String(h.term || '').trim().split(/\s+/).filter(Boolean).length;
    termsByBucket[h.bucket].add(`${(h.term||'').toLowerCase().trim()}__LEN${len}`);
  }
  return { byBucket, termsByBucket, tokens };
}

/** Enforce JSON "eligibility.clear" gates (phrase-level, excludeTokens, overshadow, prefer-caution) */
function enforceBucketGuardsV2(
  dist: Record<Bucket, number>,
  text: string,
  attachmentStyle: string = 'secure'
): Record<Bucket, number> {
  const map = dataLoader.get('toneBucketMapping') || dataLoader.get('toneBucketMap') || {};
  const EL = map?.eligibility?.clear;
  if (!EL) return dist;

  let out = { ...dist };
  const evidence = collectBucketEvidenceV2(text);

  // 1) require phrase-level & exclude generic tokens from contributing to clear
  if (EL.requirePhraseLevel || EL.minNgram || EL.excludeTokens) {
    const entries = Array.from(evidence.termsByBucket.clear || []);
    const onlyGeneric = (() => {
      if (!entries.length) return true;
      const minN = EL.minNgram ?? 2;
      const exclude = new Set((EL.excludeTokens||[]).map((t:string)=>t.toLowerCase()));
      for (const tagged of entries) {
        const [term, lenTag] = tagged.split('__LEN');
        const n = parseInt(lenTag||'1',10)||1;
        if (n >= minN && !exclude.has(term.trim())) return false;
      }
      return true;
    })();
    if (onlyGeneric) {
      out.clear = Math.min(out.clear, 0.01);
      out = normBuckets(out);
    }
  }

  // 2) overshadow: if alert strong and clear not sufficiently larger, dampen clear
  if (EL.overshadow?.by === 'alert') {
    const min = EL.overshadow.min ?? 0.22;
    const ratio = EL.overshadow.ratio ?? 1.75;
    if (out.alert >= min && out.clear < out.alert * ratio) {
      out.clear = Math.min(out.clear, out.alert * 0.25);
      out = normBuckets(out);
    }
  }

  // 3) prefer caution if both clear & alert present
  const prefer = EL.preferCautionIfBoth ?? 0.18;
  if (out.clear >= prefer && out.alert >= prefer) {
    const bleed = Math.min(0.15, out.clear * 0.25);
    out = normBuckets({ clear: out.clear - bleed, caution: out.caution + bleed, alert: out.alert });
  }

  return out;
}

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

    // Step 2: Extend profanity index with morphological variants (auto-generated from base forms)
    const profanityWithVariants = new Set(profanityWords);
    const morphVariants = (base: string): string[] => {
      if (!base || base.length < 3) return [base];
      return [
        // Progressive/gerund forms
        base.endsWith('e') ? base.slice(0,-1) + 'ing' : base + 'ing',
        // Past tense
        base.endsWith('e') ? base + 'd' : (base.endsWith('y') && !base.match(/[aeiou]y$/)) 
          ? base.slice(0,-1) + 'ied' : base + 'ed',
        // Plural/3rd person
        base.endsWith('s') || base.endsWith('sh') || base.endsWith('ch') || base.endsWith('x') || base.endsWith('z')
          ? base + 'es' : base.endsWith('y') && !base.match(/[aeiou]y$/)
          ? base.slice(0,-1) + 'ies' : base + 's',
        // Simple variants
        base + 'er', base + 'ing', base + 'ed'
      ].filter((v,i,arr) => v.length >= 3 && arr.indexOf(v) === i);
    };
    
    for (const word of profanityWords) {
      if (word && word.length >= 3) {
        for (const variant of morphVariants(word)) {
          profanityWithVariants.add(variant);
        }
      }
    }
    this.profanity = Array.from(profanityWithVariants);
    logger.info(`Extended profanity index: ${profanityWords.length} base → ${this.profanity.length} total (+${this.profanity.length - profanityWords.length} variants)`);

    // Load tone patterns (optional, won't break boot if missing)
    const tpRaw = dataLoader.get('tonePatterns') || dataLoader.get('tone_patterns');
    const tonePatterns = Array.isArray(tpRaw) ? tpRaw : (tpRaw?.patterns || []);
    if (Array.isArray(tonePatterns) && tonePatterns.length > 0) {
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
    const normalizedText = normalizeForProfanity(text);
    // Use word boundaries to avoid false positives like "class" triggering "ass"
    const found = this.profanity.some(w => {
      // Create word boundary regex for each profanity word
      const regex = new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
      return regex.test(normalizedText);
    });
    logger.info(`Profanity check: text="${normalizedText}", profanityWords=[${this.profanity.slice(0, 5).join(', ')}...], found=${found}`);
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
    const normalizedText = normalizeForProfanity(text);
    const hits: ProfHit[] = [];
    let maxSeverity: ProfSeverity | 'none' = 'none';
    
    // Get profanity data with severity levels from JSON
    const prof = dataLoader.get('profanityLexicons');
    if (prof?.categories) {
      for (const category of prof.categories) {
        if (category.triggerWords && Array.isArray(category.triggerWords)) {
          const severity = (category.severity as ProfSeverity) || 'mild';
          
          for (const word of category.triggerWords) {
            const normalizedWord = normalizeForProfanity(word);
            const regex = new RegExp(`\\b${normalizedWord.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'gi');
            let match;
            
            while ((match = regex.exec(normalizedText)) !== null) {
              hits.push({
                term: word,
                severity,
                start: match.index,
                end: match.index + match[0].length
              });
              
              // Track highest severity
              if (severity === 'strong' || (severity === 'moderate' && maxSeverity !== 'strong') || 
                  (severity === 'mild' && maxSeverity === 'none')) {
                maxSeverity = severity;
              }
            }
          }
        }
      }
    }

    // Check for second-person targeting
    const hasSecondPerson = /\byou(r|'re|re|)\b/.test(normalizedText);
    const hasTargetedSecondPerson = hits.length > 0 && hasSecondPerson;

    return {
      hasProfanity: hits.length > 0,
      count: hits.length,
      matches: hits.map(h => h.term),
      hasTargetedSecondPerson,
      severity: maxSeverity
    };
  }

  // Step 5: New method with detailed hit positions and severity support
  scanProfanityWithDetails(text: string): ProfHit[] {
    const normalizedText = normalizeForProfanity(text);
    const hits: ProfHit[] = [];
    
    // Get profanity data with severity levels
    const prof = dataLoader.get('profanityLexicons');
    if (!prof?.categories) return hits;
    
    for (const category of prof.categories) {
      if (!category.triggerWords || !Array.isArray(category.triggerWords)) continue;
      
      const severity = (category.severity as ProfSeverity) || 'mild';
      
      for (const word of category.triggerWords) {
        const normalizedWord = normalizeForProfanity(word);
        const regex = new RegExp(`\\b${normalizedWord.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'gi');
        let match;
        
        while ((match = regex.exec(normalizedText)) !== null) {
          // Check for second-person targeting context
          const beforeMatch = normalizedText.slice(Math.max(0, match.index - 20), match.index);
          const afterMatch = normalizedText.slice(match.index + match[0].length, match.index + match[0].length + 20);
          const contextText = beforeMatch + match[0] + afterMatch;
          const hasTargeting = /\byou(r|'re|re|)\b/.test(contextText);
          
          hits.push({
            term: word,
            severity,
            start: match.index,
            end: match.index + match[0].length,
            targetedSecondPerson: hasTargeting
          });
        }
      }
    }
    
    // Sort by position for consistent ordering
    return hits.sort((a, b) => a.start - b.start);
  }

  // Steps 6-7: Streaming profanity detection for live typing
  scanProfanityStreaming(text: string, isPartial: boolean = false): ProfHit[] {
    const normalizedText = normalizeForProfanity(text);
    const hits: ProfHit[] = [];
    
    // Get profanity data
    const prof = dataLoader.get('profanityLexicons');
    if (!prof?.categories) return hits;
    
    for (const category of prof.categories) {
      if (!category.triggerWords || !Array.isArray(category.triggerWords)) continue;
      
      const severity = (category.severity as ProfSeverity) || 'mild';
      
      for (const word of category.triggerWords) {
        const normalizedWord = normalizeForProfanity(word);
        
        if (isPartial) {
          // For partial text, check if the end of text could be starting a profanity word
          // Look for partial matches where the text ends mid-word
          const textWords = normalizedText.split(/\s+/);
          const lastWord = textWords[textWords.length - 1] || '';
          
          if (lastWord.length >= 2 && normalizedWord.startsWith(lastWord)) {
            const textStart = normalizedText.lastIndexOf(lastWord);
            hits.push({
              term: word,
              severity,
              start: textStart,
              end: textStart + lastWord.length,
              partialMatch: true
            });
          }
        }
        
        // Standard full-word matches
        const regex = new RegExp(`\\b${normalizedWord.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'gi');
        let match;
        
        while ((match = regex.exec(normalizedText)) !== null) {
          // Check for second-person targeting context
          const beforeMatch = normalizedText.slice(Math.max(0, match.index - 20), match.index);
          const afterMatch = normalizedText.slice(match.index + match[0].length, match.index + match[0].length + 20);
          const contextText = beforeMatch + match[0] + afterMatch;
          const hasTargeting = /\byou(r|'re|re|)\b/.test(contextText);
          
          hits.push({
            term: word,
            severity,
            start: match.index,
            end: match.index + match[0].length,
            partialMatch: false,
            targetedSecondPerson: hasTargeting
          });
        }
      }
    }
    
    // Sort by position and prioritize complete matches over partial ones
    return hits.sort((a, b) => {
      if (a.start !== b.start) return a.start - b.start;
      // Complete matches first, then partial
      return (a.partialMatch ? 1 : 0) - (b.partialMatch ? 1 : 0);
    });
  }

  getProfanityCount() { return this.profanity.length; }
}

const detectors = new ToneDetectors();

// -----------------------------
// Bucket mapping from JSON
// -----------------------------
// Maps tone -> {clear,caution,alert} using toneBucketMapping v2.1.1 (no eligibility here)
// Eligibility is applied later with enforceBucketGuardsV2(), where we have access to the raw text.
function mapBucketsFromJson(
  toneLabel: string,
  contextKey: string,
  intensity: number,
  contextSeverity?: Record<Bucket, number>,
  metaClassifier?: { pAlert: number, pCaution: number },
  bypassOverrides?: boolean, // Deprecated - no longer used
  text?: string // Deprecated - no longer used
): { primary: Bucket, dist: Record<Bucket, number>, meta: any } {
  const map = dataLoader.get('toneBucketMapping') || dataLoader.get('toneBucketMap') || {};
  const TB = map.toneBuckets || {};

  // Get base distribution from tone configuration - NO OVERRIDES
  const toneConfig = TB[toneLabel] || {};
  const base =
    toneConfig?.base ||
    TB[map.defaultBucket || 'neutral']?.base ||
    TB['neutral']?.base ||
    { clear:0.5, caution:0.3, alert:0.2 };

  // Use pure base distribution - no modifications
  const dist: Record<Bucket, number> = { ...base };
  
  logger.info(`✅ PURE BASE: Using clean base distribution for tone: ${toneLabel}`, { base, dist });
  
  // Return primary bucket based on highest probability
  const primary = (Object.entries(dist).sort((a,b)=>b[1]-a[1])[0][0]) as Bucket;
  
  return { 
    primary, 
    dist, 
    meta: { 
      toneLabel, 
      contextKey, 
      intensity, 
      source: 'pure_base',
      overridesRemoved: true 
    } 
  };
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
  
  // Provisional lock mechanism for streaming stability
  private lockUntil = 0;
  private lockTone: Bucket | null = null;

  constructor(contextKey: string, attachmentStyle: string) {
    this.contextKey = contextKey;
    this.attachmentStyle = attachmentStyle;
  }

  // Lock tone for specified duration to prevent flicker - Fix #4: Reduce default lock time
  private tryLock(tone: Bucket, ms = 600) {  // Reduced default from 1200ms to 600ms
    this.lockTone = tone;
    this.lockUntil = Date.now() + ms;
    logger.info(`🔒 Tone locked: ${tone} for ${ms}ms`);
  }

  // Get current tone distribution with lock consideration
  getCurrent(): Record<Bucket, number> {
    if (Date.now() < this.lockUntil && this.lockTone) {
      const locked: Record<Bucket, number> = { clear: 0, caution: 0, alert: 0 };
      locked[this.lockTone] = 1;
      return locked;
    }
    return { ...this.lastDist };
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

    // Enhanced guardrail: profanity instantly nudges toward alert
    const profanityCheck = detectors.analyzeProfanity(txt);
    if (profanityCheck.hasProfanity) { 
      // Scale alert boost by severity
      let alertBoost = 0.3;
      if (profanityCheck.severity === 'strong') alertBoost = 0.6;
      else if (profanityCheck.severity === 'moderate') alertBoost = 0.4;
      
      log.alert += alertBoost; 
      log.clear -= 0.1;
      
      // Trigger provisional lock for strong profanity
      if (profanityCheck.severity === 'strong' || profanityCheck.hasTargetedSecondPerson) {
        this.tryLock('alert', 500);  // Reduced from 1200ms
      }
    }

    // Check for high-impact triggers that should lock alert tone
    let shouldLockAlert = false;
    let shouldLockCaution = false;
    
    // Threat patterns
    if (/\b(i('| )?ll|i will|im (?:gonna|going to))\b.*\b(hurt|hit|ruin|report|expose|fire|destroy)\b|\bor else\b/i.test(txt)) {
      log.alert += 0.8;
      shouldLockAlert = true;
    }
    
    // Targeted imperatives with "you"
    if (/\b(you|ur|youre|you're|u|ya)\b/i.test(txt) && 
        /\b(shut|stop|leave|go|die|listen|get|move)\b/i.test(txt)) {
      log.alert += 0.6;
      shouldLockAlert = true;
    }
    
    // Dismissive with heat
    if (/\b(whatever|obviously|as usual)\b/i.test(txt) && 
        (/[!?]{2,}/.test(txt) || /\b(you|your)\b/i.test(txt))) {
      log.caution += 0.4;
      shouldLockCaution = true;
    }
    
    // Apply provisional locks for streaming stability - Fix #4: Reduce sticky alert locks
    if (shouldLockAlert) {
      this.tryLock('alert', 400);  // Reduced from 1000ms to 400ms
    } else if (shouldLockCaution) {
      this.tryLock('caution', 400); // Reduced from 800ms to 400ms  
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

    // Update conversation memory for hysteresis tracking
    const primaryTone: Bucket = this.lastDist.alert > this.lastDist.caution && this.lastDist.alert > this.lastDist.clear ? 'alert' :
                               this.lastDist.caution > this.lastDist.clear ? 'caution' : 'clear';
    
    const fieldId = `stream_${this.contextKey}_${this.attachmentStyle}`;
    const secondPersonCount = (txt.match(/\b(you|your|ur)\b/gi) || []).length;
    const addressee = txt.match(/@[\w._-]+/) ? txt.match(/@[\w._-]+/)![0] : null;
    
    conversationMemory.set(fieldId, {
      lastTone: primaryTone,
      lastTimestamp: Date.now(),
      lastSecondPersonCount: secondPersonCount,
      lastAddressee: addressee
    });

    this.tokens = [];
  }
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
      joy: [
        'happy','excited','thrilled','delighted','joyful','glad','cheerful','ecstatic',
        'great','awesome','amazing','excellent','fantastic','nice','good','well done','proud'
      ],
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
    // Base (code) weights — safe if JSON missing
    const W = {
      emo: 0.40, ctx: 0.20, attach: 0.15, ling: 0.15,
      intensity: 0.10, negPenalty: 0.15, sarcPenalty: 0.18, absolutesBoost: 0.06
    };

    const wm = getWeightMods();
    if (!wm) return W;

    const { key, reason } = resolveContextKey(context);

    if (key !== '__code_default__') {
      const deltas = wm.byContext?.[key];
      if (deltas) {
        // additive deltas with bounds
        (Object.keys(W) as Array<keyof typeof W>).forEach(k => {
          const delta = typeof deltas[k] === 'number' ? (deltas as any)[k] : 0;
          (W as any)[k] = Math.max(wm.bounds?.min ?? 0, Math.min(wm.bounds?.max ?? 1, (W as any)[k] + delta));
        });
      }
    }

    // Telemetry (optional)
    if (wm.fallbacks?.enabled && WEIGHTS_FALLBACK_EVENT) {
      try { logger.info(WEIGHTS_FALLBACK_EVENT, { ctx_in: context, ctx_used: key, reason }); } catch {}
    }

    return W;
  }

// ========= High-Impact Alert/Caution Detection Functions =========

  // 1) Targeted imperative detection: "you" + imperative verb within 4 tokens → alert
  private targetedImperative(doc: any, text: string = ''): boolean {
    if (!doc?.tokens?.length) return false;
    const lower = text.toLowerCase();

    // Hard positivity veto (common praise phrases)
    const POS_VETO = /\b(great|awesome|amazing|excellent|nice|good|well done|proud|thank you|appreciate)\b/;
    if (POS_VETO.test(lower)) return false;

    // Imperative verb list (base-form commands)
    const IMPERATIVES = new Set([
      'stop','shut','leave','go','listen','get','move','give','keep','quit','drop','cut','watch','look','wait'
    ]);

    // Exclude copulas/aux/weak verbs
    const FORBIDDEN_LEMMAS = new Set(['be','am','is','are','was','were','have','has','had','do','does','did']);

    // Helper: second-person nearby
    const isYou = (s: string) => /\b(you|ur|youre|you're|u|ya)\b/i.test(s);

    // 1) Classic imperative at sentence start without explicit "you"
    const first = doc.tokens[0];
    if (first && (first.pos === 'VERB' || first.tag === 'VB')) {
      const lem = (first.lemma || first.text || '').toLowerCase();
      if (IMPERATIVES.has(lem) && !/\byou(r|)\b/i.test(lower)) return true;
    }

    // 2) "you" + imperative within window, but only for real commands & with harshness
    for (let i = 0; i < doc.tokens.length; i++) {
      const t = doc.tokens[i];
      const lemma = (t.lemma || t.text || '').toLowerCase();

      if (t.pos !== 'VERB' && t.tag !== 'VB') continue;
      if (FORBIDDEN_LEMMAS.has(lemma)) continue;            // ignore be/have/do etc.
      if (!IMPERATIVES.has(lemma)) continue;                // must be a command verb

      const lo = Math.max(0, i - 4), hi = Math.min(doc.tokens.length - 1, i + 4);
      let hasYou = false;
      for (let j = lo; j <= hi; j++) {
        if (isYou((doc.tokens[j].text || '').toLowerCase())) { hasYou = true; break; }
      }
      if (!hasYou) continue;

      // require some "heat" when explicit "you" is present (to avoid benign "you are …")
      const HAS_HEAT = /!|(?:\bnow\b|\bright now\b|\bat once\b)/.test(lower);
      if (HAS_HEAT) return true;
    }

    return false;
  }

  // 2) Threat intent detection: "I'll hurt you", "or else", etc.
  private detectThreatIntent(text: string): boolean {
    const THREAT_RE = /\b(i('| )?ll|i will|im (?:gonna|going to))\b.*\b(hurt|hit|ruin|report|expose|fire|destroy|kill|harm|get|make you|fuck you up)\b|\bor else\b|\bi will make you\b/i;
    return THREAT_RE.test(text);
  }

  // 3) Dismissive markers for caution: "whatever", "obviously", etc.
  private detectDismissiveMarkers(text: string): number {
    const DISMISSIVE_PATTERNS = [
      /\bwhatever\b/i,
      /\bobviously\b/i, 
      /\bas usual\b/i,
      /\bsure\s*🙄/i,
      /\bof course\b.*\bnot\b/i,
      /\bgreat\b.*(?:\.|!{1,3})\s*$/i  // sarcastic "great."
    ];
    
    let score = 0;
    for (const pattern of DISMISSIVE_PATTERNS) {
      if (pattern.test(text)) score += 0.3;
    }
    
    // Check for repair cues that might negate dismissiveness
    const REPAIR_CUES = /\b(let's|we should|how about|maybe we|i think we should|let me|can we)\b/i;
    if (score > 0 && REPAIR_CUES.test(text)) {
      score *= 0.4; // Reduce but don't eliminate
    }
    
    return Math.min(1.0, score);
  }

  // 4) Rhetorical question heat: multiple ?! or "why are you so [insult]"
  private detectRhetoricalQuestionHeat(text: string): number {
    let score = 0;
    
    // Multiple punctuation marks
    if (/[?!]{2,}/.test(text)) score += 0.4;
    
    // "Why are you so [negative adjective]" pattern
    if (/\bwhy\s+are\s+you\s+(so\s+)?(stupid|dumb|incompetent|ridiculous|useless|pathetic|annoying|selfish)\b/i.test(text)) {
      score += 0.6;
    }
    
    // General hostile questioning pattern
    if (/\bwhy\s+do\s+you\s+(always|never|constantly)\b/i.test(text)) {
      score += 0.3;
    }
    
    return Math.min(1.0, score);
  }

  // 5) Enhanced homoglyph and leetspeak normalization
  private normalizeConfusables(text: string): string {
    const HOMOGLYPH_MAP: Record<string, string> = {
      '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't',
      '@': 'a', '$': 's', '!': 'i', '|': 'l', '()': 'o'
    };
    
    let normalized = text;
    for (const [glyph, replacement] of Object.entries(HOMOGLYPH_MAP)) {
      normalized = normalized.replace(new RegExp(glyph, 'g'), replacement);
    }
    
    return normalized;
  }

  // 6) Emoji escalation detection
  private detectEmojiEscalation(text: string): { angerBoost: number; sarcasmBoost: number } {
    const ANGER_EMOJI = /💢|😡|🤬|🖕|🚫|🔥/;
    const FAKE_SOFTENER = /🙂/;
    
    let angerBoost = 0;
    let sarcasmBoost = 0;
    
    if (ANGER_EMOJI.test(text)) {
      angerBoost += 0.4;
    }
    
    // Detect fake softener: 🙂 with insults/profanity
    if (FAKE_SOFTENER.test(text) && 
        (/\b(you|your|ur)\b/i.test(text)) && 
        (detectors.analyzeProfanity(text).hasProfanity || /\b(stupid|idiot|clown|loser|pathetic)\b/i.test(text))) {
      sarcasmBoost += 0.3;
      angerBoost += 0.2; // Also bump anger for sarcastic hostility
    }
    
    return { angerBoost, sarcasmBoost };
  }

  // 7) Belittling constructions and stronger intent cues
  private detectBelittlingConstructions(text: string): { cautionBoost: number; disableSofteners: boolean } {
    const BELITTLING_PATTERNS = [
      /\bno offense,?\s+but\b/i,
      /\bwith all due respect,?\s+/i,
      /\bcalm down\b/i,
      /\brelax\b(?:\s|$)/i,
      /\btake it easy\b/i,
      /\bjust saying\b/i,
      /\bdon't get me wrong,?\s+but\b/i
    ];
    
    let cautionBoost = 0;
    let disableSofteners = false;
    
    for (const pattern of BELITTLING_PATTERNS) {
      if (pattern.test(text)) {
        cautionBoost += 0.4;
        disableSofteners = true; // Disable softeners for the next clause
        logger.info(`😒 Belittling construction detected: ${pattern.source}`);
      }
    }
    
    return { cautionBoost, disableSofteners };
  }

  // 8) Enhanced irony/sarcasm detection
  private detectAdvancedSarcasm(text: string): number {
    let sarcasmScore = 0;
    
    // Praise + insult pattern: "Great job, genius"
    if (/\b(great|nice|good|excellent|perfect|wonderful)\b.*\b(genius|hero|einstein|brilliant)\b/i.test(text) &&
        /[.!,]/.test(text)) {
      sarcasmScore += 0.6;
    }
    
    // Backhanded compliments with "but"
    if (/\bnot\s+(stupid|dumb|incompetent)\b.*\bbut\b/i.test(text)) {
      sarcasmScore += 0.4;
    }
    
    // Fake positivity with 🙂 and criticism
    if (/🙂/.test(text) && /\b(you|your)\b/i.test(text) && 
        /\b(need to|should|have to|must|better)\b/i.test(text)) {
      sarcasmScore += 0.5;
    }
    
    return Math.min(1.0, sarcasmScore);
  }

  // 9) Prosody-like signals from text
  private detectProsodySignals(text: string): { intensityBoost: number; cautionBoost: number } {
    let intensityBoost = 0;
    let cautionBoost = 0;
    
    // Ellipses after "you" or commands (passive aggression)
    if (/\b(you|your)\b.*\.{2,}/i.test(text) || /\w+\.{2,}/.test(text)) {
      cautionBoost += 0.3;
      intensityBoost += 0.2;
    }
    
    // Word stretch (re-elongation after normalization)
    const stretchMatches = text.match(/\b\w*([a-z])\1{2,}\w*\b/gi);
    if (stretchMatches && stretchMatches.length > 0) {
      intensityBoost += Math.min(0.4, stretchMatches.length * 0.1);
    }
    
    // Interrobang patterns
    if (/\?!|\!\?/.test(text)) {
      if (/\b(you|your|ur)\b/i.test(text)) {
        cautionBoost += 0.4; // Alert if targeted
      } else {
        cautionBoost += 0.2; // General emphasis
      }
    }
    
    return { intensityBoost, cautionBoost };
  }

  // 10) Conversation awareness with micro-context
  private updateConversationMemory(fieldId: string, currentTone: Bucket, text: string): void {
    const secondPersonCount = (text.match(/\b(you|your|ur)\b/gi) || []).length;
    const addressee = text.match(/@[\w._-]+/) ? text.match(/@[\w._-]+/)![0] : null;
    
    conversationMemory.set(fieldId, {
      lastTone: currentTone,
      lastTimestamp: Date.now(),
      lastSecondPersonCount: secondPersonCount,
      lastAddressee: addressee
    });
  }

  private checkConversationHysteresis(fieldId: string, text: string): { cautionBoost: number; alertBoost: number } {
    const memory = conversationMemory.get(fieldId);
    if (!memory) return { cautionBoost: 0, alertBoost: 0 };
    
    const timeSinceLastMs = Date.now() - memory.lastTimestamp;
    if (timeSinceLastMs > 10000) return { cautionBoost: 0, alertBoost: 0 }; // Too old, ignore
    
    let cautionBoost = 0;
    let alertBoost = 0;
    
    // If previous was alert and current contains defensive markers, keep caution
    if (memory.lastTone === 'alert' && 
        /\b(i'm just saying|relax|calm down|whatever|fine)\b/i.test(text)) {
      cautionBoost += 0.4;
    }
    
    // Two consecutive absolutes with second person within 5 seconds → escalate
    const currentSecondPerson = (text.match(/\b(you|your|ur)\b/gi) || []).length;
    const hasAbsolutes = /\b(always|never|every time|constantly|literally)\b/i.test(text);
    
    if (timeSinceLastMs < 5000 && 
        memory.lastSecondPersonCount > 0 && currentSecondPerson > 0 && 
        hasAbsolutes) {
      alertBoost += 0.6;
      logger.info('🔄 Conversation hysteresis: consecutive absolutes + second person → alert escalation');
    }
    
    return { cautionBoost, alertBoost };
  }

  // 11) Evidential confidence and explanation
  private computeEvidentialConfidence(signals: string[], weights: number[]): { confidence: number; explanation: string[] } {
    if (signals.length === 0) return { confidence: 1.0, explanation: [] };
    
    const avgWeight = weights.reduce((sum, w) => sum + w, 0) / weights.length;
    const evidence = signals.length * avgWeight;
    
    // Reduce confidence when signals disagree (e.g., positive + insult)
    const hasPositive = signals.some(s => s.includes('positive') || s.includes('supportive'));
    const hasNegative = signals.some(s => s.includes('anger') || s.includes('threat') || s.includes('profanity'));
    
    let confidence = Math.min(1.0, evidence / 2.0);
    if (hasPositive && hasNegative) {
      confidence *= 0.7; // Conflicting signals reduce confidence
    }
    
    // Return top 3 signals for explanation
    const topSignals = signals
      .map((signal, i) => ({ signal, weight: weights[i] || 0 }))
      .sort((a, b) => b.weight - a.weight)
      .slice(0, 3)
      .map(item => item.signal);
    
    return { confidence, explanation: topSignals };
  }

  // ========= Meta-Classifier for Human-like Judgments =========
  
  // Utility functions for learned layer
  private sigmoid(z: number): number {
    return 1 / (1 + Math.exp(-z));
  }

  private metaAlertProb(x: number[], w: number[]): number {
    let z = 0;
    for (let i = 0; i < x.length; i++) {
      z += (w[i] || 0) * x[i];
    }
    return this.sigmoid(z);
  }

  private metaCautionProb(x: number[], w: number[]): number {
    let z = 0;
    for (let i = 0; i < x.length; i++) {
      z += (w[i] || 0) * x[i];
    }
    return this.sigmoid(z);
  }

  // Build feature vector for meta-classifier
  private buildMetaFeatures(text: string, f: any, profanityAnalysis: any, doc: any, contextDetection: any): number[] {
    const clamp01 = (x: number) => Math.max(0, Math.min(1, x));
    
    return [
      profanityAnalysis.severity === 'strong' ? 1 : 0,                    // [0] strong profanity
      profanityAnalysis.severity === 'moderate' ? 1 : 0,                  // [1] moderate profanity
      profanityAnalysis.hasTargetedSecondPerson ? 1 : 0,                  // [2] targeted profanity
      doc ? (this.targetedImperative(doc, text) ? 1 : 0) : 0,                   // [3] targeted imperative
      this.detectThreatIntent(text) ? 1 : 0,                              // [4] threat patterns
      clamp01((f.lng_absolutes || 0) / 3),                                // [5] absolutes (normalized)
      clamp01((f.int_exc || 0) / 3) + clamp01((f.int_q || 0) / 3) + clamp01(f.int_caps_ratio || 0), // [6] punctuation heat
      /💢|😡|🤬|🖕/.test(text) ? 1 : 0,                                    // [7] anger emojis
      /\bwhy\b.*\b(stupid|dumb|ridiculous|incompetent)\b/i.test(text) ? 1 : 0, // [8] hostile questioning
      /(?:obviously|clearly|as usual)\b/i.test(text) ? 1 : 0,             // [9] dismissive markers
      contextDetection.primaryContext?.includes('conflict') ? 1 : 0,       // [10] conflict context
      doc?.sarcasmCue ? 1 : 0                                             // [11] sarcasm cue
    ];
  }

  // Conservatively initialized weights (will be refined with data)
  private readonly W_ALERT = [1.4, 0.9, 1.2, 0.9, 1.1, 0.6, 0.7, 0.5, 0.7, 0.5, 0.4, 0.4];
  private readonly W_CAUTION = [0.2, 0.5, 0.4, 0.3, 0.2, 0.8, 0.7, 0.2, 0.6, 0.7, 0.3, 0.5];

  private _scoreTones(fr: any, text: string, attachmentStyle: string, contextHint: string, doc?: any) {
    const f = fr.features || {};
    
    // Early compliment guard: short-circuit negative boosts
    const COMPLIMENT = /\b(you\s+(are|did|do|sound|look)\s+(so\s+)?(great|awesome|amazing|excellent|good|fantastic)|great\s+(work|job)|nice\s+(work|job)|well\s+done)\b/i;
    const THANKING   = /\b(thank you|thanks(?: a lot)?|appreciate(?: it)?|grateful)\b/i;
    const isCompliment = COMPLIMENT.test(text) || THANKING.test(text);
    
    const W = this._weights(contextHint);
    const out: any = { 
      neutral: 0.1, positive: 0.1, supportive: 0.1, 
      anxious: 0, angry: 0, frustrated: 0, sad: 0, assertive: 0 
    };

    if (isCompliment) {
      // Pre-boost supportive/positive; zero-out any pending hostility bumps
      // (lets truly hostile signals re-accumulate if present later)
      // Minimal, safe nudge:
      out.supportive += 0.6;
      out.positive   += 0.4;
    }

    // Enhanced profanity analysis (single call, structured result) - Fix #5: Cache profanity analysis
    const profanityAnalysis = detectors.analyzeProfanity(text);
    (fr as any).profanityAnalysis = profanityAnalysis; // Store for reuse to avoid redundant calls

    // ========= Apply High-Impact Alert/Caution Detection Upgrades =========
    
    // 1) Targeted imperative detection
    const hasTargetedImperative = doc ? this.targetedImperative(doc, text) : false;
    if (!isCompliment && hasTargetedImperative) {
      out.angry += 1.0;
      logger.info('🎯 Targeted imperative detected → alert boost');
    }

    // 2) Threat intent detection
    if (!isCompliment && this.detectThreatIntent(text)) {
      out.angry += 1.2;
      logger.info('⚠️ Threat intent detected → alert boost');
    }

    // 3) Dismissive markers
    const dismissiveScore = this.detectDismissiveMarkers(text);
    if (!isCompliment && dismissiveScore > 0) {
      out.frustrated += dismissiveScore * 0.8;
      out.angry += dismissiveScore * 0.4;
      logger.info(`😤 Dismissive markers detected (${dismissiveScore.toFixed(2)}) → caution boost`);
    }

    // 4) Rhetorical question heat
    const questionHeat = this.detectRhetoricalQuestionHeat(text);
    if (!isCompliment && questionHeat > 0) {
      out.frustrated += questionHeat;
      out.angry += questionHeat * 0.6;
      logger.info(`❓ Rhetorical question heat (${questionHeat.toFixed(2)}) → caution boost`);
    }

    // 5) Emoji escalation detection
    const emojiDetection = this.detectEmojiEscalation(text);
    if (!isCompliment && emojiDetection.angerBoost > 0) {
      out.angry += emojiDetection.angerBoost;
      logger.info(`😡 Anger emoji boost (${emojiDetection.angerBoost.toFixed(2)})`);
    }
    if (!isCompliment && emojiDetection.sarcasmBoost > 0) {
      out.angry += emojiDetection.sarcasmBoost;
      out.frustrated += emojiDetection.sarcasmBoost * 0.7;
      logger.info(`🙂 Fake softener sarcasm boost (${emojiDetection.sarcasmBoost.toFixed(2)})`);
    }

    // 6) Belittling constructions
    const belittlingDetection = this.detectBelittlingConstructions(text);
    if (belittlingDetection.cautionBoost > 0) {
      out.frustrated += belittlingDetection.cautionBoost;
      out.angry += belittlingDetection.cautionBoost * 0.6;
      logger.info(`😒 Belittling construction boost (${belittlingDetection.cautionBoost.toFixed(2)})`);
    }

    // 7) Advanced sarcasm detection
    const sarcasmScore = this.detectAdvancedSarcasm(text);
    if (sarcasmScore > 0) {
      out.angry += sarcasmScore * 0.8;
      out.frustrated += sarcasmScore * 0.6;
      logger.info(`😏 Advanced sarcasm detected (${sarcasmScore.toFixed(2)})`);
    }

    // 8) Prosody signals
    const prosodySignals = this.detectProsodySignals(text);
    if (prosodySignals.cautionBoost > 0) {
      out.frustrated += prosodySignals.cautionBoost;
      out.angry += prosodySignals.cautionBoost * 0.5;
      logger.info(`⌨️ Prosody signals (${prosodySignals.cautionBoost.toFixed(2)})`);
    }

    // ========= End Individual Upgrades =========

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

    // ========= Meta-Classifier Integration =========
    
    // Build feature vector for learned layer
    const metaFeatures = this.buildMetaFeatures(text, f, profanityAnalysis, doc, contextDetection);
    
    // Compute meta-classifier probabilities
    let pAlert = this.metaAlertProb(metaFeatures, this.W_ALERT);
    let pCaution = this.metaCautionProb(metaFeatures, this.W_CAUTION);
    
    // Positivity guard for meta layer
    const HAS_POSITIVE = /\b(great|awesome|amazing|excellent|nice|good|well done|proud|thank you|appreciate)\b/i.test(text);
    const NO_NEG_MARKERS =
      !profanityAnalysis.hasProfanity &&
      !this.detectThreatIntent(text) &&
      !this.detectRhetoricalQuestionHeat(text) &&
      !this.detectDismissiveMarkers(text);

    if (HAS_POSITIVE && NO_NEG_MARKERS) {
      pAlert   = Math.min(pAlert, 0.15);
      pCaution = Math.min(pCaution, 0.25);
    }
    
    // REMOVED: Double counting meta-classifier into scores - only apply at bucket level
    // out.angry += pAlert * 0.3;
    // out.frustrated += Math.max(0, pCaution - pAlert * 0.3) * 0.9;
    
    logger.info(`🧠 Meta-classifier: pAlert=${pAlert.toFixed(3)}, pCaution=${pCaution.toFixed(3)}`);

    // ========= Conversation Awareness =========
    
    // Check conversation hysteresis (requires fieldId - we'll use a hash of text for now)
    const fieldId = `field_${require('crypto').createHash('md5').update(text.substring(0, 50)).digest('hex').substring(0, 8)}`;
    const hysteresis = this.checkConversationHysteresis(fieldId, text);
    
    if (hysteresis.cautionBoost > 0) {
      out.frustrated += hysteresis.cautionBoost;
      out.angry += hysteresis.cautionBoost * 0.5;
    }
    if (hysteresis.alertBoost > 0) {
      out.angry += hysteresis.alertBoost;
    }

    // ========= End Advanced Upgrades =========

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
    // Fix #3: Gate caps by negativity to prevent enthusiasm misclassification
    const hasNegativeTone = (f.angry || 0) + (f.frustrated || 0) + (f.hostile || 0) > 0.1;
    const capsContribution = hasNegativeTone ? (f.int_caps_ratio || 0) * 0.8 : (f.int_caps_ratio || 0) * 0.15;
    
    const intensity = clamp01(
      (f.int_q || 0) * 0.05 + 
      (f.int_exc || 0) * 0.08 + 
      capsContribution + 
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

    // Compute evidential confidence and explanation
    const detectedSignals: string[] = [];
    const signalWeights: number[] = [];
    
    if (hasTargetedImperative) { detectedSignals.push('targeted imperative'); signalWeights.push(1.0); }
    if (this.detectThreatIntent(text)) { detectedSignals.push('threat intent'); signalWeights.push(1.2); }
    if (profanityAnalysis.hasProfanity) { 
      detectedSignals.push(`${profanityAnalysis.severity} profanity`); 
      signalWeights.push(profanityAnalysis.severity === 'strong' ? 1.4 : profanityAnalysis.severity === 'moderate' ? 0.9 : 0.5); 
    }
    if (emojiDetection.angerBoost > 0) { detectedSignals.push('anger emojis'); signalWeights.push(0.5); }
    if (dismissiveScore > 0) { detectedSignals.push('dismissive language'); signalWeights.push(0.4); }
    if (questionHeat > 0) { detectedSignals.push('hostile questioning'); signalWeights.push(0.7); }
    if (pAlert > 0.7) { detectedSignals.push('meta-classifier alert'); signalWeights.push(pAlert * 1.4); }
    if (pCaution > 0.6) { detectedSignals.push('meta-classifier caution'); signalWeights.push(pCaution * 0.9); }
    
    const evidentialResult = this.computeEvidentialConfidence(detectedSignals, signalWeights);

    for (const k of Object.keys(out)) out[k] = Math.max(0, out[k]);
    return { 
      scores: out, 
      intensity, 
      confidence: evidentialResult.confidence,
      explanation: evidentialResult.explanation,
      metaClassifier: { pAlert, pCaution },
      signals: detectedSignals
    };
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

      // POS-aware intensity facets - Fix #3: Gate caps by negativity
      const advBump = doc.tokens.filter(t => t.pos === 'ADV').length * 0.04;
      const excl = (text.match(/!/g)||[]).length * 0.08;
      const q = (text.match(/\?/g)||[]).length * 0.04;
      
      // Only treat caps as intensity for negative contexts
      const hasNegativeWords = /(hate|angry|mad|stupid|worst|terrible|awful|damn|hell)/.test(text.toLowerCase());
      const caps = hasNegativeWords ? 
        (text.match(/[A-Z]{2,}/g)||[]).length * 0.12 : 
        (text.match(/[A-Z]{2,}/g)||[]).length * 0.03;

      // Score
      logger.info('Scoring tones');
      const contextForWeights = doc.contextLabel || options.context || 'general';
      
      // Debug: verify what context key was used during scoring
      const resolved = resolveContextKey(contextForWeights);
      logger.info('weights.context_resolved', resolved);
      
      const { scores, intensity: baseIntensity } = this._scoreTones(fr, text, style, contextForWeights, doc);
      const intensity = clamp01(baseIntensity + advBump + excl + q + caps);
      
      // �️ Smart Safety Rails: Boost meta-classifier signals instead of hardcoded overrides
      const T = text.toLowerCase();
      const secondPerson = /\byou(r|'re|re|)\b/.test(T) || (fr.features?.lng_second ?? 0) > 0;
      
      // Use enhanced profanity analysis from scoring
      const profanityAnalysis = (fr as any).profanityAnalysis || detectors.analyzeProfanity(text);
      
      logger.info(`Safety rail check: text="${text}", hasProfanity=${profanityAnalysis.hasProfanity}, hasTargetedSecondPerson=${profanityAnalysis.hasTargetedSecondPerson}, severity=${profanityAnalysis.severity}, matches=${profanityAnalysis.matches.join(',')}`);
      
      // Smart safety rails: boost alert signals for dangerous content without hardcoding distributions
      let safetyBoost = 0;
      let safetyReason = '';
      
      if (profanityAnalysis.hasTargetedSecondPerson) {
        safetyBoost = 0.8; // Very high boost for targeted profanity
        safetyReason = 'targeted profanity detected';
      } else if (profanityAnalysis.hasProfanity && profanityAnalysis.severity === 'strong') {
        safetyBoost = 0.6; // High boost for strong profanity
        safetyReason = 'strong profanity detected';
      } else if (profanityAnalysis.hasProfanity && profanityAnalysis.severity === 'moderate' && secondPerson) {
        safetyBoost = 0.4; // Moderate boost for moderate profanity + targeting
        safetyReason = 'moderate profanity with targeting detected';
      }
      
      if (safetyBoost > 0) {
        logger.info(`🛡️ SAFETY RAIL TRIGGERED: ${safetyReason} => boosting alert signal by ${safetyBoost}`);
        
        // Boost the alert features that meta-classifier will consider
        // This lets the meta-classifier make the final decision with enhanced signal strength
        scores.angry = Math.max(scores.angry ?? 0, (scores.angry ?? 0) + safetyBoost);
        
        // Note: Profanity signals are already added to detectedSignals in _scoreTones method
        // This safety rail just boosts the scores, letting meta-classifier make final bucketing decision
      }
      
      logger.info('Tones scored', { scores, intensity });

      // Softmax
      const distribution = this._softmaxScores(scores);
      let classification = this._primaryFromDist(distribution);
      let confidence = distribution[classification] || 0.33;
      
      // Note: Removed old hard-floor classification override - safety rails now boost signals instead
      // This allows meta-classifier to make intelligent bucketing decisions
      
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
    negationIndicators: dataLoader.get('negationPatterns') || dataLoader.get('negationIndicators'),
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

  // Optional guard application if caller provides raw text
  try {
    if (config?.text) {
      buckets = enforceBucketGuardsV2(buckets, String(config.text || ''), attachmentStyle);
    }
  } catch {}
  
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
    
    // Get pure base distribution without any overrides or guards
    const bucketResult = mapBucketsFromJson(
      result.primary_tone, 
      context, 
      result.intensity
    );
    
    // Use the clean distribution directly - no guards, no overrides
    const cleanDist = bucketResult.dist;
    const primaryBucket = (Object.entries(cleanDist).sort((a,b)=>b[1]-a[1])[0][0]) as Bucket;
    
    return {
      tone: result.primary_tone,
      confidence: result.confidence,
      buckets: cleanDist,
      primary_bucket: primaryBucket,
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
