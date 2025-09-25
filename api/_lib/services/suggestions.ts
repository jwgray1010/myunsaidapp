// api/_lib/services/suggestions.ts
/**
 * Advanced ML-Enhanced Suggestions API (Therapy-Advice Focus)
 *
 * This implementation:
 *  - Uses ONLY local JSON knowledge bases + spaCy (via toneAnalysis) — no LLM calls
 *  - Hybrid retrieval (BM25 + embeddings) with MMR diversity
 *  - Context/attachment-aware scoring with JSON-driven weights/overrides
 *  - Guardrails & contraindications from JSON, no risky fallbacks
 *  - Confidence calibration per context (evaluation_tones.json)
 *  - Returns your existing SuggestionAnalysis shape
 */

import { logger } from '../logger';
import { dataLoader } from './dataLoader';
import { processWithSpacy } from './spacyBridge';
import { spacyClient } from './spacyClient';
import { getAdviceCandidates } from './adviceIndex';
import { foldAttachmentPatterns } from '../utils/foldAttachmentPatterns';
import { CommunicatorProfile } from './communicatorProfile';
import type {
  TherapyAdvice
} from '../types/dataTypes';
import type { ToneResponse } from '../schemas/toneRequest';
import { matchSemanticBackbone, applySemanticBias, type SemanticBackboneResult } from './utils/semanticBackbone';
import { isContextAppropriate, logContextFilter, getContextLinkBonus, type ContextScores } from './contextAnalysis';
import { nliLocal, hypothesisForAdvice, detectUserIntents, type FitResult } from './nliLocal';

// Environment variable controls for production tuning
const ENV_CONTROLS = {
  // Retrieval and ranking
  RETRIEVAL_POOL_SIZE: Number(process.env.RETRIEVAL_POOL_SIZE) || 120,
  MMR_LAMBDA: Number(process.env.MMR_LAMBDA) || 0.7,
  MAX_SUGGESTIONS: Number(process.env.MAX_SUGGESTIONS) || 5,
  
  // NLI processing
  NLI_MAX_ITEMS: Number(process.env.NLI_MAX_ITEMS) || 60,
  NLI_BATCH_SIZE: Number(process.env.NLI_BATCH_SIZE) || 8,
  NLI_TIMEOUT_MS: Number(process.env.NLI_TIMEOUT_MS) || 500,
  NLI_ENTAIL_MIN_DEFAULT: Number(process.env.NLI_ENTAIL_MIN_DEFAULT) || 0.55,
  NLI_CONTRA_MAX_DEFAULT: Number(process.env.NLI_CONTRA_MAX_DEFAULT) || 0.20,
  
  // Cache and performance
  HYPOTHESIS_CACHE_MAX: Number(process.env.HYPOTHESIS_CACHE_MAX) || 1000,
  VECTOR_CACHE_MAX: Number(process.env.VECTOR_CACHE_MAX) || 1000,
  TONE_BUCKET_CACHE_MAX: Number(process.env.TONE_BUCKET_CACHE_MAX) || 200,
  PERFORMANCE_CACHE_MAX: Number(process.env.PERFORMANCE_CACHE_MAX) || 1000,
  
  // Context processing
  MAX_CONTEXT_LINK_BONUS: Number(process.env.MAX_CONTEXT_LINK_BONUS) || 0.12,
  CONTEXT_SCORE_THRESHOLD: Number(process.env.CONTEXT_SCORE_THRESHOLD) || 0.05,
  
  // Feature flags
  DISABLE_NLI: process.env.DISABLE_NLI === '1',
  DISABLE_WEIGHT_FALLBACKS: process.env.DISABLE_WEIGHT_FALLBACKS === '1',
  
  // Cache Management
  CACHE_EXPIRY_MS: Number(process.env.CACHE_EXPIRY_MS) || (30 * 60 * 1000), // 30 minutes default
  CACHE_CLEANUP_PERCENTAGE: Number(process.env.CACHE_CLEANUP_PERCENTAGE) || 0.2, // 20% default
  
  // Search Parameters
  BM25_LIMIT: Number(process.env.BM25_LIMIT) || 200,
  MMR_K: Number(process.env.MMR_K) || 200
};

// Performance optimization: memoization caches
const hypothesisCache = new Map<string, string>(); // advice.id -> hypothesis
const toneBucketCache = new Map<string, any>(); // toneKey -> bucket result
const vectorCache = new Map<string, Float32Array | null>(); // id -> vector (module-level LRU)

// ---- Aho-Corasick Automaton for Fast Pattern Matching ----
/**
 * Simplified Aho-Corasick implementation with basic trie + fallback safety.
 * 
 * Performance Notes:
 * - Uses simplified failure links (all point to root) for speed over completeness
 * - Provides O(n) text scanning for most patterns, but may miss some overlaps  
 * - Always paired with regex fallbacks for accuracy guarantee
 * - Suitable for large lexicons due to fast prefix sharing in trie structure
 * - Exception handling prevents disruption of ranking pipeline
 * 
 * This is a "best-effort" implementation optimized for speed with safety nets.
 */
class AhoCorasickAutomaton {
  private patterns: Map<string, string[]> = new Map();
  private compiled = false;
  private trie: any = {};
  private failures: Map<any, any> = new Map();

  addPatterns(category: string, patterns: string[]) {
    this.patterns.set(category, patterns);
    this.compiled = false;
  }

  compile() {
    if (this.compiled) return;
    
    this.trie = {};
    this.failures.clear();
    
    // Build trie
    for (const [category, patterns] of this.patterns) {
      for (const pattern of patterns) {
        this.addToTrie(pattern.toLowerCase(), category);
      }
    }
    
    // Build failure links (simplified implementation)
    this.buildFailures();
    this.compiled = true;
  }

  private addToTrie(pattern: string, category: string) {
    let node = this.trie;
    for (const char of pattern) {
      if (!node[char]) {
        node[char] = {};
      }
      node = node[char];
    }
    if (!node.output) node.output = [];
    node.output.push({ category, pattern });
  }

  private buildFailures() {
    // Simplified failure function for basic Aho-Corasick
    // In production, you'd use a proper AC implementation
    const queue: any[] = [];
    
    // Set failure for depth 1
    for (const char in this.trie) {
      if (this.trie[char] && typeof this.trie[char] === 'object') {
        this.failures.set(this.trie[char], this.trie);
        queue.push(this.trie[char]);
      }
    }
    
    // Build remaining failures
    while (queue.length > 0) {
      const node = queue.shift();
      for (const char in node) {
        if (char === 'output') continue;
        const child = node[char];
        if (child && typeof child === 'object') {
          queue.push(child);
          this.failures.set(child, this.trie);
        }
      }
    }
  }

  search(text: string): { category: string, match: string, position: number }[] {
    if (!this.compiled) this.compile();
    
    const results: { category: string, match: string, position: number }[] = [];
    const lowerText = text.toLowerCase();
    const seen = new Set<string>(); // Prevent duplicate category matches
    let node = this.trie;
    
    for (let i = 0; i < lowerText.length; i++) {
      const char = lowerText[i];
      
      // Try to match
      while (node && !node[char]) {
        node = this.failures.get(node) || this.trie;
      }
      
      if (node && node[char]) {
        node = node[char];
        
        // Check for matches with deduplication
        if (node.output) {
          for (const output of node.output) {
            const { category, pattern } = output;
            if (seen.has(category)) continue; // Skip already found categories
            seen.add(category);
            const patternLength = pattern.length;
            const matchText = lowerText.slice(i - patternLength + 1, i + 1);
            results.push({
              category,
              match: matchText,
              position: i
            });
          }
        }
      } else {
        node = this.trie;
      }
    }
    
    return results;
  }
}

// Global Aho-Corasick automaton instance
let globalAutomaton: AhoCorasickAutomaton | null = null;

function getOrCreateAutomaton(): AhoCorasickAutomaton {
  if (!globalAutomaton) {
    globalAutomaton = new AhoCorasickAutomaton();
    
    try {
      // Load phrase edges
      const phraseEdges = dataLoader.get('phraseEdges') || {};
      Object.entries(phraseEdges).forEach(([category, patterns]: [string, any]) => {
        if (Array.isArray(patterns)) {
          globalAutomaton!.addPatterns(`phrase_${category}`, patterns);
        }
      });
      
      // ✅ LOAD LEARNING SIGNALS PATTERNS for communication pattern detection
      const learningSignals = dataLoader.get('learningSignals') || {};
      if (learningSignals.features && Array.isArray(learningSignals.features)) {
        for (const feature of learningSignals.features) {
          if (feature.patterns && Array.isArray(feature.patterns) && feature.buckets) {
            const patterns = feature.patterns.map((p: string) => {
              // Convert regex patterns to simple strings for Aho-Corasick
              return p.replace(/\\b/g, '').replace(/\([^)]*\)/g, '').replace(/[|]/g, ' ').split(' ').filter(s => s.length > 2);
            }).flat();
            
            // Add patterns for each bucket this feature maps to
            for (const bucket of feature.buckets) {
              globalAutomaton!.addPatterns(`ls_${bucket}`, patterns);
            }
            
            // Also add under the feature ID for direct lookup
            globalAutomaton!.addPatterns(`ls_feature_${feature.id}`, patterns);
          }
        }
        logger.info('Learning signals patterns loaded into automaton', { 
          featureCount: learningSignals.features.length 
        });
      }
      
      // Load guardrail patterns
      const guardrails = dataLoader.get('guardrailConfig') || {};
      if (guardrails.blockedPatterns) {
        globalAutomaton!.addPatterns('blocked', guardrails.blockedPatterns);
      }
      if (guardrails.softenerPatterns) {
        globalAutomaton!.addPatterns('softener', guardrails.softenerPatterns);
      }
      if (guardrails.gentlePatterns) {
        globalAutomaton!.addPatterns('gentle', guardrails.gentlePatterns);
      }
      
      // Add second-person patterns
      const secondPersonPatterns = [
        // direct
        'you are', 'you were', 'you will', 'you would', 'you can', 'you could', 
        'you should', 'you need', 'you have', 'you had', 'you do', 'you did',
        'you don\'t', 'you didn\'t', 'you won\'t', 'you wouldn\'t',
        'you\'re', 'you\'ve', 'you\'ll', 'you\'d',
        'your', 'yours', 'yourself',
        // indirect
        'if you', 'when you', 'have you', 'do you', 'would you', 'could you'
      ];
      globalAutomaton!.addPatterns('second_person', secondPersonPatterns);
      
      globalAutomaton!.compile();
      logger.info('Aho-Corasick automaton compiled successfully');
    } catch (error) {
      logger.warn('Failed to compile Aho-Corasick automaton', { error });
    }
  }
  
  return globalAutomaton;
}

// ---- weight-mod fallback resolver (exact → alias → family → general → code_default)
const DISABLE_WEIGHT_FALLBACKS = ENV_CONTROLS.DISABLE_WEIGHT_FALLBACKS;
const WEIGHTS_FALLBACK_EVENT_SUG = 'weights.fallback.suggestions';

function getWeightMods() { return dataLoader.get('weightModifiers'); }

type ResolvedCtx = { key: string; reason: string };
function resolveWeightContextKey(rawCtx: string): ResolvedCtx {
  const wm = getWeightMods();
  const ctx = (rawCtx || 'general').toLowerCase().trim();

  if (!wm || DISABLE_WEIGHT_FALLBACKS) {
    return { key: ctx, reason: wm ? 'nofallbacks_env' : 'nofallbacks_missing_config' };
  }

  const byContext = wm.adviceRankOverrides?.byContext || wm.suggestionsByContext || wm.byContext || {};
  const aliasMap  = wm.aliasMap  || {};
  const familyMap = wm.familyMap || {};

  if (byContext[ctx]) return { key: ctx, reason: 'exact' };

  const aliased = aliasMap[ctx];
  if (aliased && byContext[aliased]) return { key: aliased, reason: `alias:${ctx}` };

  const fam = familyMap[ctx];
  if (fam && byContext[fam]) return { key: fam, reason: `family:${ctx}` };

  if (byContext.general) return { key: 'general', reason: `fallback:general(${ctx})` };

  return { key: '__code_default__', reason: `fallback:code_default(${ctx})` };
}

// Utility helper to check for specific categories in Aho-Corasick matches
function acHasCategory(text: string, category: string): boolean {
  try { 
    return getOrCreateAutomaton().search(text).some(m => m.category === category); 
  } catch { 
    return false; 
  }
}

// ✅ LEARNING SIGNALS COMMUNICATION PATTERN DETECTION - mirrors normalize.ts
function detectCommunicationPatterns(text: string): {
  patterns: string[];
  buckets: string[];
  scores: Record<string, number>;
  attachment_hints: Record<string, number>;
  noticings: string[];
} {
  if (!text || typeof text !== 'string') {
    return { patterns: [], buckets: [], scores: {}, attachment_hints: {}, noticings: [] };
  }
  
  const detectedPatterns: string[] = [];
  const detectedBuckets: Set<string> = new Set();
  const scores: Record<string, number> = {};
  const attachmentHints: Record<string, number> = {};
  const noticings: string[] = [];
  
  const learningSignals = dataLoader.get('learningSignals');
  if (!learningSignals?.features) {
    return { patterns: [], buckets: [], scores: {}, attachment_hints: {}, noticings: [] };
  }
  
  // Process each learning signal feature
  for (const feature of learningSignals.features) {
    if (!feature.patterns || !Array.isArray(feature.patterns)) continue;
    
    let hasMatch = false;
    for (const patternStr of feature.patterns) {
      try {
        const regex = new RegExp(patternStr, 'gi');
        if (text.match(regex)) {
          hasMatch = true;
          break;
        }
      } catch (err) {
        // Skip invalid patterns
        continue;
      }
    }
    
    if (hasMatch) {
      detectedPatterns.push(feature.id);
      
      // Add buckets
      if (feature.buckets && Array.isArray(feature.buckets)) {
        for (const bucket of feature.buckets) {
          detectedBuckets.add(bucket);
        }
      }
      
      // Add tone weight scores  
      if (feature.weights) {
        for (const [tone, weight] of Object.entries(feature.weights)) {
          if (typeof weight === 'number') {
            scores[tone] = (scores[tone] || 0) + weight;
          }
        }
      }
      
      // Add attachment hints
      if (feature.attachmentHints) {
        for (const [style, hint] of Object.entries(feature.attachmentHints)) {
          if (typeof hint === 'number') {
            attachmentHints[style] = (attachmentHints[style] || 0) + hint;
          }
        }
      }
    }
  }
  
  // Add noticings from noticingsMap
  const noticingsMap = learningSignals.noticingsMap || {};
  for (const bucket of detectedBuckets) {
    if (noticingsMap[bucket] && typeof noticingsMap[bucket] === 'string') {
      noticings.push(noticingsMap[bucket]);
    }
  }
  
  return {
    patterns: detectedPatterns,
    buckets: Array.from(detectedBuckets),
    scores,
    attachment_hints: attachmentHints,
    noticings: noticings.slice(0, 3) // Max 3 noticings per message per learning_signals.json
  };
}

// ============================
// Interfaces (keep identical to your original)
// ============================
export interface DetailedSuggestionResult {
  id: string;
  text: string;
  type: 'advice' | 'emotional_support' | 'communication_guidance' | 'boundary_setting' | 'conflict_resolution';
  confidence: number;
  reason: string;
  category: 'communication' | 'emotional' | 'relationship' | 'conflict_resolution';
  priority: number;
  context_specific: boolean;
  attachment_informed: boolean;
  // optional metadata
  categories?: string[];
}

export interface SuggestionAnalysis {
  success: boolean;
  tier: 'general' | 'premium';
  original_text: string;
  context: string;
  suggestions: DetailedSuggestionResult[];
  analysis: {
    tone: {
      classification: string;
      confidence: number;
    };
    mlGenerated: boolean;
    context: {
      label: string;
      score: number;
    };
    flags: {
      hasNegation: boolean;
      hasSarcasm: boolean;
      intensityScore: number;
      phraseEdgeHits: string[];
    };
    toneBuckets: {
      primary: string;
      dist: {
        clear: number;
        caution: number;
        alert: number;
      };
    };
  };
  analysis_meta: {
    complexity_score: number;
    emotional_intensity: number;
    clarity_level: number;
    empathy_present: boolean;
    potential_triggers: string[];
    recommended_approach: string;
  };
  metadata: {
    attachmentStyle: string;
    timestamp: string;
    version: string;
  };
  trialStatus: any;
}

type Bucket = 'clear'|'caution'|'alert';

interface ToneBucketDistribution {
  clear: number;
  caution: number;
  alert: number;
}

interface ToneBucketResult {
  primary: string;
  dist: ToneBucketDistribution;
}

// ============================
// Comprehensive JSON Data Loader Enforcement
// ============================
async function ensureDataLoaded(): Promise<void> {
  // DataLoader is now pre-initialized synchronously
  if (!dataLoader.isInitialized()) {
    logger.warn('DataLoader not initialized in suggestions service');
  }

  const requiredJSONFiles = [
    'therapy_advice.json',
    'context_classifier.json', 
    'tone_triggerwords.json',
    'negation_patterns.json',
    'sarcasm_indicators.json',
    'intensity_modifiers.json',
    'phrase_edges.json',
    'tone_bucket_mapping.json',
    'weight_modifiers.json',
    'guardrail_config.json',
    'profanity_lexicons.json',
    'attachment_overrides.json',
    'attachment_tone_weights.json',
    'semantic_thesaurus.json',
    'learning_signals.json',
    'evaluation_tones.json',
    'user_preference.json'
  ];

  logger.info('Ensuring all JSON data files are loaded...');
  
  // Check data status
  const dataStatus = dataLoader.getDataStatus();
  const missingFiles: string[] = [];
  
  for (const fileName of requiredJSONFiles) {
    if (!dataStatus[fileName]) {
      missingFiles.push(fileName);
      logger.error(`✗ Critical JSON dependency missing: ${fileName}`);
    } else {
      logger.debug(`✓ ${fileName} available`);
    }
  }
  
  if (missingFiles.length > 0) {
    throw new Error(`Critical JSON dependencies missing: ${missingFiles.join(', ')}`);
  }
  
  // Validate core data can be accessed
  const therapyAdvice = dataLoader.get('therapyAdvice');
  const toneBucketMapping = dataLoader.get('toneBucketMapping');
  const guardrailConfig = dataLoader.get('guardrailConfig');
  
  if (!therapyAdvice || !toneBucketMapping || !guardrailConfig) {
    throw new Error('Core JSON data structures not properly loaded');
  }
  
  logger.info('All JSON data files validated and loaded');
}

// ============================
// Trial Manager (no network, simple gate)
// ============================
class TrialManager {
  async getTrialStatus(userId: string = 'anonymous', userEmail?: string | null) {
    return {
      status: 'trial_active',
      inTrial: true,
      planType: 'trial',
      features: { 'tone-analysis': true, suggestions: true, advice: true },
      isActive: true,
      hasAccess: true,
      isAdmin: false,
      daysRemaining: 5,
      totalTrialDays: 7,
      userId,
      userEmail,
      timestamp: new Date().toISOString()
    };
  }
  resolveTier(trialStatus: any): 'general' | 'premium' {
    if (trialStatus?.hasAccess && (trialStatus?.inTrial || trialStatus?.planType === 'premium')) return 'premium';
    return 'general';
  }
}

// ============================
// Performance Optimizations
// ============================
interface CacheEntry {
  result: any;
  timestamp: number;
  hits: number;
}

class PerformanceCache {
  private analysisCache = new Map<string, CacheEntry>();
  private suggestionCache = new Map<string, CacheEntry>();
  private readonly maxCacheSize = ENV_CONTROLS.PERFORMANCE_CACHE_MAX;
  private readonly cacheExpiryMs = ENV_CONTROLS.CACHE_EXPIRY_MS;

  private generateCacheKey(text: string, context?: string, attachmentStyle?: string): string {
    const normalized = text.toLowerCase().trim().replace(/\s+/g, ' ');
    return `${normalized}:${context || 'general'}:${attachmentStyle || 'secure'}`;
  }

  getCachedAnalysis(text: string, context?: string, attachmentStyle?: string): any | null {
    const key = this.generateCacheKey(text, context, attachmentStyle);
    const entry = this.analysisCache.get(key);
    
    if (!entry) return null;
    
    // Check expiry
    if (Date.now() - entry.timestamp > this.cacheExpiryMs) {
      this.analysisCache.delete(key);
      return null;
    }
    
    entry.hits++;
    return entry.result;
  }

  setCachedAnalysis(text: string, result: any, context?: string, attachmentStyle?: string): void {
    const key = this.generateCacheKey(text, context, attachmentStyle);
    
    // Clean up old entries if cache is full
    if (this.analysisCache.size >= this.maxCacheSize) {
      this.evictOldEntries(this.analysisCache);
    }
    
    this.analysisCache.set(key, {
      result: JSON.parse(JSON.stringify(result)), // Deep clone
      timestamp: Date.now(),
      hits: 1
    });
  }

  getCachedSuggestions(analysisKey: string, maxSuggestions: number, tier: string): any[] | null {
    const key = `${analysisKey}:${maxSuggestions}:${tier}`;
    const entry = this.suggestionCache.get(key);
    
    if (!entry) return null;
    
    // Check expiry
    if (Date.now() - entry.timestamp > this.cacheExpiryMs) {
      this.suggestionCache.delete(key);
      return null;
    }
    
    entry.hits++;
    return entry.result;
  }

  setCachedSuggestions(analysisKey: string, suggestions: any[], maxSuggestions: number, tier: string): void {
    const key = `${analysisKey}:${maxSuggestions}:${tier}`;
    
    // Clean up old entries if cache is full
    if (this.suggestionCache.size >= this.maxCacheSize) {
      this.evictOldEntries(this.suggestionCache);
    }
    
    this.suggestionCache.set(key, {
      result: JSON.parse(JSON.stringify(suggestions)), // Deep clone
      timestamp: Date.now(),
      hits: 1
    });
  }

  private evictOldEntries(cache: Map<string, CacheEntry>): void {
    // Remove least recently used entries (lowest hits + oldest timestamp)
    const entries = Array.from(cache.entries())
      .sort((a, b) => (a[1].hits + a[1].timestamp / 1000000) - (b[1].hits + b[1].timestamp / 1000000))
      .slice(0, Math.floor(this.maxCacheSize * ENV_CONTROLS.CACHE_CLEANUP_PERCENTAGE)); // Environment controlled percentage
    
    for (const [key] of entries) {
      cache.delete(key);
    }
  }

  getStats(): { analysisEntries: number; suggestionEntries: number; totalHits: number } {
    const analysisHits = Array.from(this.analysisCache.values()).reduce((sum, entry) => sum + entry.hits, 0);
    const suggestionHits = Array.from(this.suggestionCache.values()).reduce((sum, entry) => sum + entry.hits, 0);
    
    return {
      analysisEntries: this.analysisCache.size,
      suggestionEntries: this.suggestionCache.size,
      totalHits: analysisHits + suggestionHits
    };
  }
}

// Global performance cache instance
const performanceCache = new PerformanceCache();

// ============================
// Helpers: retrieval / guardrails / calibration
// ============================
function cosine(a: Float32Array, b: Float32Array): number {
  let dot = 0, na = 0, nb = 0;
  for (let i=0;i<a.length;i++){ const x=a[i], y=b[i]; dot+=x*y; na+=x*x; nb+=y*y; }
  const d = Math.sqrt(na)*Math.sqrt(nb) || 1;
  return dot/d;
}

function getAdviceCorpus(): any[] {
  const idxItems = dataLoader.get('adviceIndexItems');
  if (Array.isArray(idxItems) && idxItems.length) return idxItems;
  const therapyAdvice = dataLoader.get('therapyAdvice');
  if (Array.isArray(therapyAdvice)) return therapyAdvice;
  return [];
}

function getVecById(id: string): Float32Array | null {
  const getter = dataLoader.get('adviceGetVector');
  if (typeof getter === 'function') {
    const v = getter(id);
    if (v && v.length) return new Float32Array(v);
  }
  return null;
}

function bm25Search(query: string, limit = ENV_CONTROLS.BM25_LIMIT): any[] {
  let bm25 = dataLoader.get('adviceBM25');
  logger.debug('bm25Search called', { 
    hasBM25: !!bm25, 
    query, 
    limit,
    bm25Type: typeof bm25
  });
  
  if (!bm25) return [];
  
  const hits = bm25.search(query, { prefix: true, fuzzy: 0.2 }).slice(0, limit);
  logger.debug('BM25 search completed', { hitsCount: hits.length });
  
  const byId = new Map<string, any>(getAdviceCorpus().map((it:any)=>[it.id, it]));
  const result = hits.map((h:any)=>byId.get(h.id)).filter(Boolean);
  logger.debug('BM25 results mapped', { finalResultCount: result.length, hitsCount: hits.length });
  
  return result;
}

function mmr(pool: any[], qVec: Float32Array | null, vecOf: (it:any)=>Float32Array|null, k=ENV_CONTROLS.MMR_K, lambda=ENV_CONTROLS.MMR_LAMBDA) {
  // Early exit for sparse-only path (no reason to compute novelty without dense vectors)
  if (!qVec) return pool.slice(0, k);
  
  const out: any[] = [];
  const cand = new Set(pool);
  while (out.length < Math.min(k, pool.length) && cand.size) {
    let best: any = null;
    let bestScore = -Infinity;
    const candidates: {item: any, score: number}[] = [];
    
    for (const it of Array.from(cand)) {
      const v = vecOf(it);
      const rel = qVec && v ? cosine(qVec, v) : 0;
      let nov = 1;
      if (out.length && v) {
        let maxSim = 0;
        for (const o of out) {
          const ov = vecOf(o);
          if (ov) maxSim = Math.max(maxSim, cosine(v, ov));
        }
        nov = 1 - maxSim;
      }
      const score = lambda*rel + (1-lambda)*nov;
      candidates.push({item: it, score});
    }
    
    // Sort candidates for deterministic tie-breaking
    candidates.sort((a, b) => {
      const scoreDiff = b.score - a.score;
      if (Math.abs(scoreDiff) > 0.0001) return scoreDiff;
      
      // Tie-breaker: category then ID
      const catA = a.item.category || a.item.categories?.[0] || 'zzz';
      const catB = b.item.category || b.item.categories?.[0] || 'zzz';
      const catDiff = catA.localeCompare(catB);
      if (catDiff !== 0) return catDiff;
      
      return (a.item.id || '').localeCompare(b.item.id || '');
    });
    
    best = candidates[0]?.item;
    bestScore = candidates[0]?.score ?? -Infinity;
    
    if (!best) break;
    out.push(best);
    cand.delete(best);
  }
  return out;
}

// Memoized helper functions for performance
function getMemoizedHypothesis(advice: any): string {
  if (!hypothesisCache.has(advice.id)) {
    hypothesisCache.set(advice.id, hypothesisForAdvice(advice));
  }
  return hypothesisCache.get(advice.id)!;
}

function getMemoizedVector(id: string): Float32Array | null {
  if (!vectorCache.has(id)) {
    // Use existing vector retrieval logic
    const vector = getVecById(id);
    vectorCache.set(id, vector);
    
    // Environment-controlled LRU: keep cache under control
    if (vectorCache.size > ENV_CONTROLS.VECTOR_CACHE_MAX) {
      const firstKey = vectorCache.keys().next().value;
      if (firstKey) vectorCache.delete(firstKey);
    }
  }
  return vectorCache.get(id) || null;
}

function getMemoizedToneBucket(toneKey: string, contextLabel: string, intensityScore: number, resolveFn: Function): any {
  const key = `${toneKey}|${contextLabel}|${Math.floor(intensityScore * 10)}`;
  if (!toneBucketCache.has(key)) {
    toneBucketCache.set(key, resolveFn(toneKey, contextLabel, intensityScore));
    
    // Environment-controlled LRU: keep cache under control
    if (toneBucketCache.size > ENV_CONTROLS.TONE_BUCKET_CACHE_MAX) {
      const firstKey = toneBucketCache.keys().next().value;
      if (firstKey) toneBucketCache.delete(firstKey);
    }
  }
  return toneBucketCache.get(key);
}

// Enhanced tone matching: supports both exact raw tone matches and UI tone fallbacks
function matchesToneClassification(item: any, toneKey: string): boolean {
  const itemTone = item.triggerTone;
  if (!itemTone) return false;
  
  // Direct match (preferred)
  if (itemTone === toneKey) return true;
  
  // Fallback matching: check if toneKey maps to the same UI bucket as itemTone
  const toneToUIBucket = (tone: string): string => {
    switch (tone) {
      case 'clear':
      case 'caution': 
      case 'alert':
        return tone; // UI tones map to themselves
      
      // Based on highest probability in tone_bucket_mapping.json
      // Positive/Supportive Communication (Clear-leaning)
      case 'supportive':      // 0.90 clear (highest)
      case 'positive':        // 0.88 clear (highest)
      case 'playful':         // 0.85 clear (highest)
      case 'curious':         // 0.82 clear (highest)
      case 'confident':       // 0.80 clear (highest)
      case 'logistical':      // 0.78 clear (highest)
      case 'reflective':      // 0.75 clear (highest)
      case 'neutral':         // 0.62 clear (highest)
        return 'clear';
      
      // Emotional Distress & Tentative Communication (Caution-leaning)
      case 'overwhelmed':     // 0.68 caution (highest)
      case 'withdrawn':       // 0.65 caution (highest)
      case 'catastrophizing': // 0.65 caution (highest)
      case 'anxious':         // 0.64 caution (highest)
      case 'sad':             // 0.62 caution (highest)
      case 'jealous_insecure': // 0.60 caution (highest)
      case 'frustrated':      // 0.58 caution (highest)
      case 'confused_ambivalent': // 0.58 caution (highest)
      case 'tentative':       // 0.56 caution (highest)
      case 'minimization':    // 0.55 caution (highest)
      case 'negative':        // 0.54 caution (highest)
      case 'defensive':       // 0.55 caution (highest)
      case 'dismissive':      // 0.50 caution (highest)
      case 'apologetic':      // 0.48 caution (highest)
      case 'assertive':       // 0.32 caution (updated for controlling language)
        return 'caution';
      
      // High-Risk Communication (Alert-leaning)
      case 'contempt':        // 0.80 alert (highest)
      case 'aggressive':      // 0.75 alert (highest)
      case 'safety_concern':  // 0.72 alert (highest)
      case 'hostile':         // 0.67 alert (highest)
      case 'angry':           // 0.50 alert (highest)
      case 'critical':        // 0.40 alert (highest)
        return 'alert';
      
      default:
        return 'clear';
    }
  };
  
  const userUIBucket = toneToUIBucket(toneKey);
  const itemUIBucket = toneToUIBucket(itemTone);
  
  // Allow cross-matching within the same UI bucket
  // e.g., "assertive" user tone can match "clear" therapy advice
  return userUIBucket === itemUIBucket;
}

// Attachment-aware tone matching: considers attachment styles when determining UI bucket mappings
function matchesToneClassificationWithAttachment(item: any, toneKey: string, attachmentStyle: string | null = null): boolean {
  const itemTone = item.triggerTone;
  if (!itemTone) return false;
  
  // Direct match (preferred)
  if (itemTone === toneKey) return true;
  
  // Get attachment-aware UI bucket mapping
  const getAttachmentAwareUIBucket = (tone: string, attachment: string | null): string => {
    // Start with base mapping
    let baseMapping = 'clear';
    
    // Base tone to UI bucket mapping (same as above but with attachment overrides)
    switch (tone) {
      case 'clear': case 'caution': case 'alert':
        return tone;
      
      // Apply base mappings first
      case 'supportive': case 'positive': case 'playful': case 'curious': 
      case 'confident': case 'logistical': case 'reflective': case 'neutral':
        baseMapping = 'clear'; break;
      
      case 'overwhelmed': case 'withdrawn': case 'catastrophizing': case 'anxious':
      case 'sad': case 'jealous_insecure': case 'frustrated': case 'confused_ambivalent':
      case 'tentative': case 'minimization': case 'negative': case 'defensive':
      case 'dismissive': case 'apologetic': case 'assertive':
        baseMapping = 'caution'; break;
        
      case 'contempt': case 'aggressive': case 'safety_concern': case 'hostile':
      case 'angry': case 'critical':
        baseMapping = 'alert'; break;
        
      default:
        baseMapping = 'clear'; break;
    }
    
    // Apply attachment-specific overrides
    if (!attachment) return baseMapping;
    
    // Avoidant attachment overrides
    if (attachment === 'avoidant') {
      if (['withdrawn', 'sad', 'anxious'].includes(tone)) return 'alert';
      if (['apologetic'].includes(tone)) return 'clear';
    }
    
    // Anxious attachment overrides  
    if (attachment === 'anxious') {
      if (tone === 'withdrawn') return 'caution'; // Stay caution, not alert
      if (['apologetic', 'jealous_insecure', 'catastrophizing', 'minimization'].includes(tone)) return 'caution';
    }
    
    // Disorganized attachment overrides
    if (attachment === 'disorganized') {
      if (['angry', 'frustrated', 'defensive', 'dismissive', 'withdrawn', 'catastrophizing', 'confused_ambivalent'].includes(tone)) {
        return baseMapping === 'alert' ? 'alert' : 'alert'; // Escalate to alert
      }
    }
    
    // Secure attachment (slight improvements)
    if (attachment === 'secure') {
      if (['assertive', 'supportive', 'reflective', 'curious'].includes(tone)) return 'clear';
    }
    
    return baseMapping;
  };
  
  const userUIBucket = getAttachmentAwareUIBucket(toneKey, attachmentStyle);
  const itemUIBucket = getAttachmentAwareUIBucket(itemTone, null); // Items don't have attachment context
  
  return userUIBucket === itemUIBucket;
}

async function hybridRetrieve(text: string, contextLabel: string, toneKey: string, analysis?: any, k=ENV_CONTROLS.RETRIEVAL_POOL_SIZE) {
  const corpus = getAdviceCorpus();
  logger.info('hybridRetrieve started', { 
    corpusSize: corpus.length, 
    contextLabel, 
    toneKey, 
    text: text.substring(0, 50),
    k 
  });
  
  // Enhanced query with Coordinator signals + semantic backbone
  const ents = (analysis?.entities || []).map((e:any)=>e.text).slice(0,8);
  const intents = analysis ? detectUserIntents(text).slice(0,5) : [];
  const semTags = (analysis?.semanticBackbone?.tags || []).slice(0,8);
  const query = [
    text,
    `ctx:${contextLabel}`,
    `tone:${toneKey}`,
    ents.length ? `ents:${ents.join(',')}` : '',
    intents.length ? `intents:${intents.join(',')}` : '',
    semTags.length ? `sem:${semTags.join(',')}` : ''
  ].filter(Boolean).join(' ');
  let denseTop: any[] = [];
  let qVec: Float32Array | null = null;

  // Vector cache for performance
  const vecCache = new Map<string, Float32Array>();
  const getV = (id:string)=> vecCache.get(id) || (()=>{ const v=getVecById(id); if (v) vecCache.set(id,v); return v; })();

  // Check if any items have vectors (not just the first one)
  const sampleWithVector = corpus.find(item => getVecById(item?.id || ''));
  const hasVecs = !!sampleWithVector;
  logger.info('Vector check', { hasVecs, sampleItemId: sampleWithVector?.id });
  
  if (hasVecs && typeof (spacyClient.embed) === 'function') {
    try {
      const qArr = await spacyClient.embed(query);
      const expectedDim = getVecById(sampleWithVector?.id || '')?.length;
      if (Array.isArray(qArr) && expectedDim && qArr.length === expectedDim) {
        qVec = new Float32Array(qArr);
      } else {
        logger.warn('Embed dim mismatch; using sparse-only', { queryDim: qArr?.length, expectedDim });
      }
    } catch (e) {
      logger.warn('Dense embed failed; using sparse-only', { error: String(e) });
    }
    
    if (qVec) {
      denseTop = corpus
        .map((it:any) => {
          const v = getV(it.id);
          const s = (v && qVec) ? cosine(v, qVec) : 0;
          return [it, s] as const;
        })
        .sort((a,b)=>b[1]-a[1])
        .slice(0, k*2)
        .map(([it])=>it);
      logger.info('Dense retrieval completed', { denseTopSize: denseTop.length });
    }
  }

  const sparseTop = bm25Search(query, k*2);
  logger.info('Sparse retrieval completed', { sparseTopSize: sparseTop.length });

  // Fallback if both retrieval methods fail
  const fallbackIfEmpty = !denseTop.length && !sparseTop.length ? corpus.slice(0, Math.min(200, corpus.length)) : [];

  const uniq = new Map<string, any>();
  for (const it of [...denseTop, ...sparseTop, ...fallbackIfEmpty]) if (it?.id && !uniq.has(it.id)) uniq.set(it.id, it);
  const pool = Array.from(uniq.values());
  logger.info('Hybrid retrieval merging completed', { 
    poolSize: pool.length, 
    denseTopSize: denseTop.length, 
    sparseTopSize: sparseTop.length,
    fallbackUsed: fallbackIfEmpty.length > 0
  });
  
  // MMR with context-aware lambda
  const retrievalConfig = dataLoader.get('retrievalConfig');
  const lambda = retrievalConfig?.mmrLambda?.[contextLabel] ?? ENV_CONTROLS.MMR_LAMBDA;
  const result = mmr(pool, qVec, (it:any)=>getV(it.id), k, lambda);
  logger.info('MMR diversification completed', { finalResultSize: result.length, lambda });
  return result;
}

function applyContraindications(items: any[], flags: {hasNegation:boolean; hasSarcasm:boolean; intensityScore:number}) {
  const guard = dataLoader.get('guardrailConfig');
  const prof  = dataLoader.get('profanityLexicons');
  return items.filter((it:any) => {
    if (flags.intensityScore > (guard?.maxIntensityForConfront ?? 0.75)) {
      if ((it.categories ?? []).includes('confrontation')) return false;
    }
    if (flags.hasNegation && it.negationSensitive) return false;
    if (prof?.block && prof.block.some((w:string)=>String(it.advice||'').toLowerCase().includes(w))) return false;
    return true;
  });
}

function applyAttachmentOverrides(items:any[], style:string) {
  const overrides = dataLoader.get('attachmentOverrides')?.[style];
  if (!overrides) return items;
  return items.map((it:any) => {
    const boosted = {...it};
    if (overrides.categoryBoost && boosted.categories?.some((c:string)=>overrides.categoryBoost.includes(c))) {
      (boosted as any).__boost = ((boosted as any).__boost ?? 0) + 0.2;
    }
    // Removed rewriteCue override logic - not applicable to therapy advice
    return boosted;
  });
}

function diversify(ranked:any[], topN=5, simThreshold=0.87) {
  const out:any[]=[];
  const vec = (it:any)=>getVecById(it.id);
  for (const r of ranked) {
    const v = vec(r);
    const dup = v && out.some(o => {
      const ov = vec(o);
      return ov ? cosine(v, ov) > simThreshold : false;
    });
    if (!dup) out.push(r);
    if (out.length >= topN) break;
  }
  return out.length ? out : ranked.slice(0, topN);
}

function calibrate(conf:number, contextLabel:string) {
  const evalSet = dataLoader.get('evaluationTones');
  const p = evalSet?.platt?.[contextLabel] ?? { a: 1, b: 0 };
  return 1 / (1 + Math.exp(-(p.a*conf + p.b)));
}

// ============================
// Orchestrator (spaCy + local analyzer only)
// ============================
class AnalysisOrchestrator {
  constructor(
    private loader: any
  ) {}

  enhancedSecondPersonDetection(text: string, spacyResult: any, fullAnalysis: any): {
    hasSecondPerson: boolean;
    confidence: number;
    patterns: string[];
    targeting: 'direct' | 'indirect' | 'none';
  } {
    const patterns: string[] = [];
    let confidence = 0;
    let targeting: 'direct' | 'indirect' | 'none' = 'none';

    // Check spaCy entities for PRON_2P
    const spacyProns = Array.isArray(fullAnalysis?.entities) 
      ? fullAnalysis.entities.filter((e:any) => e.label === 'PRON_2P') 
      : [];
    
    if (spacyProns.length > 0) {
      patterns.push('spaCy_PRON_2P');
      confidence += 0.8;
      targeting = 'direct';
    }

    // Use Aho-Corasick automaton for fast pattern matching
    try {
      const automaton = getOrCreateAutomaton();
      const matches = automaton.search(text);
      
      for (const match of matches) {
        if (match.category === 'second_person') {
          patterns.push(`aho_${match.match}`);
          
          // Classify as direct or indirect based on the matched pattern
          const matchText = match.match.toLowerCase();
          if (matchText.includes('you are') || matchText.includes('you\'re') || 
              matchText.includes('your') || matchText.includes('yourself')) {
            confidence += 0.6;
            if (targeting === 'none') targeting = 'direct';
          } else if (matchText.includes('if you') || matchText.includes('when you') || 
                     matchText.includes('do you') || matchText.includes('would you')) {
            confidence += 0.3;
            if (targeting === 'none') targeting = 'indirect';
          } else {
            confidence += 0.4;
            if (targeting === 'none') targeting = 'indirect';
          }
        }
      }
    } catch (error) {
      logger.warn('Aho-Corasick automaton failed, falling back to regex', { error });
      
      // Fallback to regex if automaton fails
      const quickPatterns = [
        /\byou\s+(are|were|will|would|can|could|should|need|have|had|do|did)\b/gi,
        /\byou['']?(re|ve|ll|d)\b/gi,
        /\byour(s?)\b/gi
      ];

      for (const pattern of quickPatterns) {
        const matches = text.match(pattern);
        if (matches) {
          patterns.push(`fallback_${pattern.source}`);
          confidence += 0.5 * matches.length;
          if (targeting === 'none') targeting = 'direct';
        }
      }
    }

    confidence = Math.min(1.0, confidence);
    const hasSecondPerson = confidence > 0.2;

    return { hasSecondPerson, confidence, patterns, targeting };
  }

  async analyze(
    text: string,
    _providedTone?: { classification: string; confidence: number } | null, // unused; Coordinator wins
    attachmentStyle?: string,
    contextHint?: string,
    fullToneAnalysis?: ToneResponse | null
  ) {
    if (!fullToneAnalysis) {
      throw new Error('Tone Suggestion Coordinator result required (fullToneAnalysis missing)');
    }

    // Keep spaCy/Aho parsing for phrase edges, entities, etc.
    const spacyResult = await processWithSpacy(text);
    const fullParsing = spacyClient.process(text);

    // Tone & confidence: use Coordinator only
    const toneResult = {
      classification: fullToneAnalysis.tone,
      confidence: fullToneAnalysis.confidence
    };

    // Context: prefer Coordinator, never overwrite with spaCy
    const contextLabel =
      fullToneAnalysis.context_analysis?.label ||
      fullToneAnalysis.context ||
      contextHint ||
      'general';

    // Intensity: prefer Coordinator; handle both object and number formats
    const coordinatorIntensity =
      (fullToneAnalysis as any)?.intensity?.score ??
      (fullToneAnalysis as any)?.metadata?.intensity ??
      null;

    // If Coordinator omitted intensity, you may *augment* with spaCy-derived hints
    const auxIntensity = (() => {
      if (coordinatorIntensity != null) return coordinatorIntensity;
      const advCount = (spacyResult.tokens || []).filter((t:any)=>String(t.pos).toUpperCase()==='ADV').length;
      const excl = (text.match(/!/g)||[]).length * 0.08;
      const q    = (text.match(/\?/g)||[]).length * 0.04;
      const caps = (text.match(/[A-Z]{2,}/g)||[]).length * 0.12;
      const mod  = fullParsing.intensity?.score || 0;
      return Math.min(1, excl + q + caps + mod + advCount*0.04);
    })();

    // Flags: prefer Coordinator signals; only fill missing with spaCy/Aho heuristics
    const coordinatorFlags = {}; // ToneResponse doesn't have flags property yet
    const negFromCoord = fullParsing.negation?.present ?? false;
    const sarcasmFromCoord = spacyResult.sarcasm?.present ?? false;
    const phraseEdges = spacyResult.phraseEdges || [];

    const secondPerson = this.enhancedSecondPersonDetection(text, spacyResult, fullParsing);

    // ✅ DETECT COMMUNICATION PATTERNS from learning signals
    const learningSignals = detectCommunicationPatterns(text);
    logger.debug('Learning signals detected', { 
      patterns: learningSignals.patterns,
      buckets: learningSignals.buckets,
      attachment_hints: learningSignals.attachment_hints,
      noticings_count: learningSignals.noticings.length
    });

    // Rich data straight from Coordinator (don't synthesize if present)
    const richToneData = {
      emotions: fullToneAnalysis.emotions,
      intensity: coordinatorIntensity ?? auxIntensity,
      linguistic_features: fullToneAnalysis.linguistic_features,
      context_analysis: fullToneAnalysis.context_analysis,
      ui_tone: fullToneAnalysis.ui_tone,
      ui_distribution: fullToneAnalysis.ui_distribution,
      evidence: fullToneAnalysis.evidence,
      attachmentInsights: fullToneAnalysis.attachmentInsights,
      
      // ✅ ADD LEARNING SIGNALS DATA to rich tone data
      learning_signals: {
        patterns_detected: learningSignals.patterns,
        communication_buckets: learningSignals.buckets,
        attachment_hints: learningSignals.attachment_hints,
        tone_adjustments: learningSignals.scores,
        therapeutic_noticings: learningSignals.noticings,
      }
    };

    // Apply semantic backbone analysis
    const semanticThesaurus = this.loader.get('semanticThesaurus');
    const semanticResult = matchSemanticBackbone(
      text, 
      attachmentStyle || 'secure', 
      semanticThesaurus
    );

    return {
      tone: toneResult,
      context: { label: contextLabel, score: fullToneAnalysis.context_analysis?.appropriateness_score ?? 0.5 },
      entities: fullParsing.entities || [],
      secondPerson,
      flags: {
        hasNegation: !!negFromCoord,
        hasSarcasm: !!sarcasmFromCoord,
        intensityScore: richToneData.intensity ?? 0,
        phraseEdgeHits: phraseEdges
      },
      features: fullParsing.features || {},
      mlGenerated: false,           // no local ML tone
      semanticBackbone: semanticResult,
      richToneData,
      
      // ✅ ADD LEARNING SIGNALS to analysis return for downstream processing
      learningSignals: {
        patterns_detected: learningSignals.patterns,
        communication_buckets: learningSignals.buckets,
        attachment_hints: learningSignals.attachment_hints,
        tone_adjustments: learningSignals.scores,
        therapeutic_noticings: learningSignals.noticings,
        total_patterns_count: learningSignals.patterns.length,
        buckets_detected_count: learningSignals.buckets.length
      }
    };
  }
}

// ============================
// Advice Engine (JSON-weighted; no fallbacks)
// ============================
class AdviceEngine {
  constructor(private loader: any) {}

  private currentWeights(contextLabel: string) {
    // base scoring weights for ranking suggestions (unchanged defaults)
    const base = {
      baseConfidence: 1.0,
      toneMatch: 2.0,
      contextMatch: 1.5,
      attachmentMatch: 1.2,
      intensityBoost: 0.6,
      negationPenalty: -0.8,
      sarcasmPenalty: -1.0,
      userPrefBoost: 0.5,
      severityFit: 1.2,
      phraseEdgeBoost: 0.4,
      premiumBoost: 0.2,
      secondPersonBoost: 0.8,
      actionabilityBoost: 0.1,
      contextLinkMultiplier: 1.0  // new tunable multiplier
    };

    const wm = getWeightMods();
    if (!wm) return base;

    // prefer a dedicated section if present; otherwise fall back to legacy byContext
    const bag = wm.adviceRankOverrides?.byContext || wm.suggestionsByContext || wm.byContext;
    if (!bag) return base;

    const { key, reason } = resolveWeightContextKey(contextLabel);
    const deltas = key !== '__code_default__' ? bag[key] : null;

    if (deltas && typeof deltas === 'object') {
      // additive deltas with gentle bounds to prevent runaway values
      const min = (wm.bounds?.minSuggestionWeight ?? -2.0);
      const max = (wm.bounds?.maxSuggestionWeight ?? 3.0);
      for (const k of Object.keys(base)) {
        const v = (deltas as any)[k];
        if (typeof v === 'number') {
          (base as any)[k] = Math.max(min, Math.min(max, (base as any)[k] + v));
        }
      }
    }

    // optional telemetry for observability
    try { logger.info(WEIGHTS_FALLBACK_EVENT_SUG, { ctx_in: contextLabel, ctx_used: key, reason }); } catch {}

    return base;
  }

  // Probabilistic bucket mapping from JSON with semantic backbone integration
  resolveToneBucket(
    toneLabel: string, 
    contextLabel: string, 
    intensityScore: number = 0,
    semanticResult?: SemanticBackboneResult
  ): ToneBucketResult {
    const map = this.loader.get('toneBucketMapping') || this.loader.get('toneBucketMap') || {};
    
    // Use JSON as source of truth for base distributions
    const tb = map?.toneBuckets?.[toneLabel];
    let dist: any = tb?.base ?? { clear: 0.33, caution: 0.33, alert: 0.33 };
    
    // Apply per-context overrides from JSON
    const ctxOv = map?.contextOverrides?.[contextLabel]?.[toneLabel];
    if (ctxOv) dist = { ...dist, ...ctxOv };
    
    // Apply semantic backbone bias if available
    if (semanticResult) {
      const semanticThesaurus = this.loader.get('semanticThesaurus');
      dist = applySemanticBias(dist, semanticResult, semanticThesaurus);
    }
    
    // Normalize after overrides and semantic bias
    let sum = Object.values(dist).reduce((a:number,b:any)=>a+(Number(b)||0),0) || 1;
    const clearVal = Number(dist.clear) || 0;
    const cautionVal = Number(dist.caution) || 0;
    const alertVal = Number(dist.alert) || 0;
    const numSum = Number(sum);
    dist = { clear: clearVal/numSum, caution: cautionVal/numSum, alert: alertVal/numSum };

    // Apply intensity shifts
    const thr = map.intensityShifts?.thresholds || { low: 0.15, med: 0.35, high: 0.60 };
    const shiftKey = intensityScore >= thr.high ? 'high' : intensityScore >= thr.med ? 'med' : 'low';
    const shift = map.intensityShifts?.[shiftKey] || { alert: 0, caution: 0, clear: 0 };

    dist = {
      clear: Math.max(0, (Number(dist.clear) ?? 0) + (Number(shift.clear) || 0)),
      caution: Math.max(0, (Number(dist.caution) ?? 0) + (Number(shift.caution) || 0)),
      alert: Math.max(0, (Number(dist.alert) ?? 0) + (Number(shift.alert) || 0)),
    };

    // Final normalization
    sum = (Number(dist.clear) ?? 0) + (Number(dist.caution) ?? 0) + (Number(dist.alert) ?? 0) || 1;
    const clearNum = Number(dist.clear) ?? 0;
    const cautionNum = Number(dist.caution) ?? 0;
    const alertNum = Number(dist.alert) ?? 0;
    const finalSum = Number(sum);
    dist.clear = clearNum / finalSum;
    dist.caution = cautionNum / finalSum;
    dist.alert = alertNum / finalSum;

    const primary = (Object.entries(dist).sort((a, b) => (b[1] as number) - (a[1] as number))[0][0]) as string;
    return { primary, dist: dist as ToneBucketDistribution };
  }

  // Helper method to get UI bucket for a given tone
  getUIBucketForTone(toneKey: string): string | null {
    const map = this.loader.get('toneBucketMapping') || this.loader.get('toneBucketMap') || {};
    const entry = map?.toneBuckets?.[toneKey];
    if (!entry || !entry.base) return null;
    
    // Return the bucket with highest probability from base distribution
    const buckets = ['clear', 'caution', 'alert'];
    let maxBucket = 'clear';
    let maxValue = 0;
    
    for (const bucket of buckets) {
      const value = Number(entry.base[bucket]) || 0;
      if (value > maxValue) {
        maxValue = value;
        maxBucket = bucket;
      }
    }
    
    return maxBucket;
  }

  // Helper method to get attachment-aware UI bucket for a given tone
  getUIBucketForToneWithAttachment(toneKey: string, attachmentStyle: string | null): string | null {
    const map = this.loader.get('toneBucketMapping') || this.loader.get('toneBucketMap') || {};
    const entry = map?.toneBuckets?.[toneKey];
    if (!entry || !entry.base) return null;
    
    // Start with base distribution
    let dist = { ...entry.base };
    
    // Apply attachment-specific overrides (these are DELTAS, not absolute values)
    if (attachmentStyle && map.attachmentOverrides?.[attachmentStyle]) {
      const overrides = map.attachmentOverrides[attachmentStyle];
      if (overrides[toneKey]) {
        // Apply the specific override deltas for this tone and attachment style
        const override = overrides[toneKey];
        Object.keys(override).forEach(bucket => {
          if (['clear', 'caution', 'alert'].includes(bucket)) {
            // Add the delta to the base value
            dist[bucket] = (dist[bucket] || 0) + Number(override[bucket]);
            // Ensure no negative probabilities
            dist[bucket] = Math.max(0, dist[bucket]);
          }
        });
        
        // Renormalize after applying deltas
        const total = (dist.clear || 0) + (dist.caution || 0) + (dist.alert || 0);
        if (total > 0) {
          dist.clear = (dist.clear || 0) / total;
          dist.caution = (dist.caution || 0) / total;
          dist.alert = (dist.alert || 0) / total;
        }
      }
    }
    
    // Return the bucket with highest probability
    const buckets = ['clear', 'caution', 'alert'];
    let maxBucket = 'clear';
    let maxValue = 0;
    
    for (const bucket of buckets) {
      const value = Number(dist[bucket]) || 0;
      if (value > maxValue) {
        maxValue = value;
        maxBucket = bucket;
      }
    }
    
    return maxBucket;
  }

  severityBaselineFor(toneKey: string, contextLabel: string): number {
    const sev = this.loader.get('severityCollab') || {};
    const bucket = sev[toneKey] || sev['clear'] || {};
    const base = bucket?.base ?? 0.35;
    const byCtx = bucket?.byContext || {};
    const ctxAdj = contextLabel ? (byCtx[contextLabel] || 0) : 0;
    return base + ctxAdj;
  }

  applyTemperatureCalibration(scores: number[], contextLabel: string, intensityScore: number): number[] {
    const cal = this.loader.get('temperatureCalibration') || {};
    
    // Get base temperature from JSON config
    let temp = cal?.baseTemperature ?? 1.0;
    
    // Apply context-specific temperature adjustments
    const ctxAdj = cal?.contextAdjustments?.[contextLabel] ?? 0;
    temp += ctxAdj;
    
    // Apply intensity-based temperature scaling
    const intAdj = cal?.intensityAdjustments || {};
    const intKey = intensityScore >= 0.6 ? 'high' : intensityScore >= 0.3 ? 'medium' : 'low';
    temp += (intAdj[intKey] ?? 0);
    
    // Ensure temperature stays in reasonable bounds
    temp = Math.max(0.1, Math.min(5.0, temp));
    
    // Apply temperature scaling with bounded input scores
    // Clamp pre-calibration scores to prevent outliers from dominating
    return scores.map(score => {
      const clampedScore = Math.max(-1, Math.min(3, score)); // Bound input
      const calibrated = clampedScore / temp;
      return Math.max(-1.5, Math.min(3.5, calibrated)); // Bound output
    });
  }

  userPrefBoostFor(adviceItem: any, userPref: any): number {
    if (!userPref || !userPref.categories) return 0;
    const cats = new Set<string>();
    if (Array.isArray(adviceItem.categories)) adviceItem.categories.forEach((c: string) => cats.add(c));
    if (adviceItem.category) cats.add(adviceItem.category);
    let boost = 0;
    for (const c of Array.from(cats)) {
      const v = userPref.categories[c];
      if (typeof v === 'number') boost += v;
    }
    return boost;
  }

  rank(items: any[], signals: {
    baseConfidence: number;
    toneKey: string;
    contextLabel: string;
    attachmentStyle: string;
    hasNegation: boolean;
    hasSarcasm: boolean;
    intensityScore: number;
    phraseEdgeHits: string[];
    userPref: any;
    tier: 'general'|'premium';
    secondPerson?: { hasSecondPerson: boolean; confidence: number; targeting: string };
    contextScores?: Record<string, number>;
    categories?: string[];
    userIntents?: string[]; // ✅ NEW: Detected user intents
    learningSignals?: {     // ✅ NEW: Learning signals from communication pattern detection
      patterns_detected: string[];
      communication_buckets: string[];
      attachment_hints: Record<string, number>;
      tone_adjustments: Record<string, number>;
      therapeutic_noticings: string[];
      total_patterns_count: number;
      buckets_detected_count: number;
    };
  }): any[] {
    const W = this.currentWeights(signals.contextLabel);

    const scored = items.map((it:any) => {
      let s = 0;
      s += W.baseConfidence * (signals.baseConfidence ?? 0.8);

      // Tone match mass
      const { dist } = this.resolveToneBucket(signals.toneKey, signals.contextLabel, signals.intensityScore);
      
      // Use enhanced tone matching - check both exact raw tone and UI bucket fallback
      const exactToneMatch = it.triggerTone === signals.toneKey;
      let toneBucket = it.triggerTone || 'clear';
      let toneMatchMass = (dist as any)[toneBucket] ?? 0.33;
      
      // If no exact match, try enhanced matching to get the appropriate UI bucket
      // Use attachment-aware matching when attachment style is available
      const hasEnhancedMatch = signals.attachmentStyle 
        ? matchesToneClassificationWithAttachment(it, signals.toneKey, signals.attachmentStyle)
        : matchesToneClassification(it, signals.toneKey);
        
      if (!exactToneMatch && hasEnhancedMatch) {
        // Get UI bucket for the raw tone and use that for scoring
        // Use attachment-aware bucket determination when available
        const uiBucket = signals.attachmentStyle
          ? this.getUIBucketForToneWithAttachment(signals.toneKey, signals.attachmentStyle)
          : this.getUIBucketForTone(signals.toneKey);
        if (uiBucket && it.triggerTone === uiBucket) {
          toneMatchMass = (dist as any)[uiBucket] ?? 0.33;
        }
      }
      
      s += W.toneMatch * toneMatchMass;

      // Context
      const ctxMatch = !it.contexts || it.contexts.length === 0 || it.contexts.includes(signals.contextLabel) ? 1 : 0;
      s += W.contextMatch * ctxMatch;
      
      // Context link bonus (use top 3 contexts from analysis)
      const topContexts = Object.entries(signals.contextScores || {})
        .sort((a, b) => (b[1] as number) - (a[1] as number))
        .map(([ctx]) => ctx)
        .filter((v, i, arr) => arr.indexOf(v) === i) // unique
        .slice(0, 3);
      
      // Auto-populate contextLink if missing
      const normalizedItem = {
        ...it,
        contextLink: Array.isArray(it.contextLink) && it.contextLink.length
          ? it.contextLink
          : (Array.isArray(it.contexts) ? it.contexts : ['general'])
      };
      
      const contextLinkBonus = getContextLinkBonus(normalizedItem, topContexts) * (W.contextLinkMultiplier ?? 1);
      const MAX_CTX_LINK_IMPACT = ENV_CONTROLS.MAX_CONTEXT_LINK_BONUS; // environment-controlled absolute cap
      s += Math.min(contextLinkBonus, MAX_CTX_LINK_IMPACT);

      // Attachment
      const attachMatch = !it.attachmentStyles || it.attachmentStyles.length === 0 || it.attachmentStyles.includes(signals.attachmentStyle) ? 1 : 0;
      s += W.attachmentMatch * attachMatch;

      // Intensity
      s += W.intensityBoost * Math.min(1, Math.max(0, signals.intensityScore));

      // Negation / Sarcasm
      if (signals.hasNegation) s += W.negationPenalty;
      if (signals.hasSarcasm) s += W.sarcasmPenalty;

      // Phrase edges
      s += W.phraseEdgeBoost * Math.min(1, (signals.phraseEdgeHits?.length || 0) / 3);

      // User preferences
      s += W.userPrefBoost * this.userPrefBoostFor(it, signals.userPref);

      // Enhanced Second-Person Detection Boost
      if (signals.secondPerson?.hasSecondPerson) {
        const spBoost = signals.secondPerson.confidence * 
          (signals.secondPerson.targeting === 'direct' ? 1.0 : 0.6);
        s += W.secondPersonBoost * spBoost;
      }

      // Severity fit vs baseline
      const baseline = this.severityBaselineFor(toneBucket, signals.contextLabel);
      const required = it.severityThreshold?.[toneBucket] ?? baseline;
      const sevDelta = Math.abs((required ?? baseline) - baseline);
      const sevScore = 1 - Math.min(sevDelta / 0.1, 1);
      s += W.severityFit * sevScore;

      // Attachment overrides boost
      if ((it as any).__boost) s += (it as any).__boost;

      // Apply attachment-style category multipliers from tone weights
      const attachmentToneConfig = dataLoader.getAttachmentToneWeights();
      const categoryMultipliers = attachmentToneConfig?.overrides?.[signals.attachmentStyle]?.category_multipliers ?? {};
      let categoryBoost = 1.0;
      
      // Check both single 'category' and array 'categories' fields
      const categories = new Set<string>();
      if (Array.isArray((it as any).categories)) {
        (it as any).categories.forEach((c: string) => categories.add(c));
      }
      if ((it as any).category) {
        categories.add((it as any).category);
      }
      
      // Apply multipliers for each matching category
      for (const category of Array.from(categories)) {
        const categoryKey = String(category).toLowerCase();
        if (categoryMultipliers[categoryKey] != null) {
          categoryBoost *= Number(categoryMultipliers[categoryKey]) || 1.0;
        }
      }
      
      // Apply the category boost as a multiplier after all additive scoring
      s *= categoryBoost;

      // ✅ Category boost from tone pattern matches for targeted therapy advice
      if (signals.categories && signals.categories.length > 0) {
        const therapyCategories = new Set(signals.categories.map(c => c.toLowerCase()));
        const adviceCategories = new Set(Array.from(categories).map(c => c.toLowerCase()));
        
        // Check for exact category matches between tone patterns and therapy advice
        const categoryOverlap = Array.from(therapyCategories).filter(tc => adviceCategories.has(tc));

        if (categoryOverlap.length > 0) {
          const categoryMatchBoost = Math.min(0.15, categoryOverlap.length * 0.05); // max +0.15
          s += categoryMatchBoost;
        }
      }

      // ✅ LEARNING SIGNALS SCORING - Communication pattern bonus
      if (signals.learningSignals) {
        const ls = signals.learningSignals;
        
        // Boost suggestions that match detected communication buckets
        if (ls.communication_buckets && ls.communication_buckets.length > 0) {
          const bucketSet = new Set(ls.communication_buckets);
          
          // Check if this suggestion's context/categories match the detected patterns
          const suggestionContexts = new Set([
            ...(it.contexts || []),
            ...(Array.isArray(it.categories) ? it.categories : []),
            it.category,
            it.triggerTone
          ].filter(Boolean).map(c => String(c).toLowerCase()));
          
          // Reward matches between detected patterns and relevant suggestions
          let patternMatchBonus = 0;
          for (const bucket of ls.communication_buckets) {
            const bucketKey = bucket.toLowerCase();
            
            // Direct bucket match (e.g., "repair_language" -> repair context)
            if (suggestionContexts.has(bucketKey) || 
                suggestionContexts.has(bucketKey.replace('_language', '')) ||
                suggestionContexts.has(bucketKey.split('_')[0])) {
              patternMatchBonus += 0.08; // +0.08 per matching pattern bucket
            }
            
            // Special semantic matches
            if ((bucket === 'validation_language' || bucket === 'repair_language') && 
                (suggestionContexts.has('emotional') || suggestionContexts.has('relationship'))) {
              patternMatchBonus += 0.05;
            }
            
            if ((bucket === 'escalation_language' || bucket === 'threats_ultimatums') && 
                (suggestionContexts.has('conflict_resolution') || suggestionContexts.has('boundary'))) {
              patternMatchBonus += 0.06;
            }
          }
          
          s += Math.min(patternMatchBonus, 0.25); // Cap at +0.25
        }
        
        // Apply tone adjustments from learning signals
        if (ls.tone_adjustments && Object.keys(ls.tone_adjustments).length > 0) {
          const toneKey = signals.toneKey.toLowerCase();
          const adjustment = ls.tone_adjustments[`tone.${toneKey}`] || ls.tone_adjustments[toneKey] || 0;
          s += adjustment * 0.5; // Scale down the direct tone adjustment
        }
        
        // Bonus for suggestions that complement detected attachment patterns
        if (ls.attachment_hints && Object.keys(ls.attachment_hints).length > 0) {
          const primaryHintStyle = Object.entries(ls.attachment_hints)
            .sort(([,a], [,b]) => b - a)[0]?.[0]; // Get the highest attachment hint
            
          if (primaryHintStyle && attachMatch > 0 && primaryHintStyle === signals.attachmentStyle) {
            s += 0.1; // +0.1 for attachment pattern consistency
          }
        }
      }

      // Enhanced actionability scoring
      const advice = String(it.advice || '');
      const adviceWords = advice.split(/\s+/).filter(w => w.length > 0);
      
      // Actionability: reward imperative phrases and concrete actions
      const actionabilityKeywords = ['try', 'consider', 'ask', 'say', 'tell', 'share', 'express', 'communicate', 'listen', 'focus', 'avoid', 'remember', 'start', 'stop', 'use', 'practice'];
      const hasActionable = actionabilityKeywords.some(keyword => 
        advice.toLowerCase().includes(keyword)
      );
      if (hasActionable) s += W.actionabilityBoost || 0.1;
      
      // Brevity: reward concise suggestions (optimal 10-25 words)
      const wordCount = adviceWords.length;
      let brevityBoost = 0;
      if (wordCount >= 10 && wordCount <= 25) {
        brevityBoost = 0.15; // Sweet spot
      } else if (wordCount >= 8 && wordCount <= 30) {
        brevityBoost = 0.08; // Good range
      } else if (wordCount > 40) {
        brevityBoost = -0.1; // Penalty for verbosity
      }
      s += brevityBoost;

      // Tier
      if (signals.tier === 'premium') s += W.premiumBoost;

      // Light online learning nudge
      const sig = dataLoader.get('learningSignals')?.byItem?.[it.id];
      if (sig) {
        const shown = Math.max(1, sig.shown || 0);
        const ctr = (sig.accepted || 0) / shown;
        const rej = (sig.rejected || 0) / shown;
        s += (ctr * 0.3) - (rej * 0.2);
      }

      // ✅ NEW: Intent-based scoring using enriched metadata
      if (signals.userIntents && signals.userIntents.length > 0 && it.intents && Array.isArray(it.intents)) {
        const userIntentsSet = new Set(signals.userIntents);
        const adviceIntentsSet = new Set(it.intents);
        
        // Calculate intent overlap
        const intentMatches = Array.from(userIntentsSet).filter(intent => adviceIntentsSet.has(intent));
        
        if (intentMatches.length > 0) {
          // Strong boost for intent matches - this is high-value targeting
          const intentMatchBoost = 0.6 * intentMatches.length; // 0.6 per intent match
          s += intentMatchBoost;
          
          // Log intent boost for observability
          logger.info('Intent boost applied', {
            adviceId: it.id,
            matchedIntents: intentMatches,
            boost: intentMatchBoost,
            userIntents: signals.userIntents,
            adviceIntents: it.intents
          });
        } else {
          // Log when we have intent data but no matches (helps identify gaps)
          logger.debug('No intent matches found', {
            adviceId: it.id,
            userIntents: signals.userIntents,
            adviceIntents: it.intents
          });
        }
      }

      return { ...it, ltrScore: Number(s.toFixed(4)) };
    });

    // Apply temperature calibration to scores
    const rawScores = scored.map(item => item.ltrScore);
    const calibratedScores = this.applyTemperatureCalibration(rawScores, signals.contextLabel, signals.intensityScore);
    
    // Update items with calibrated scores
    scored.forEach((item, idx) => {
      item.ltrScore = Number(calibratedScores[idx].toFixed(4));
    });

    // Apply duplicate penalty based on Jaccard similarity
    const jaccardSimilarity = (text1: string, text2: string): number => {
      const words1 = new Set(text1.toLowerCase().split(/\s+/).filter(w => w.length > 2));
      const words2 = new Set(text2.toLowerCase().split(/\s+/).filter(w => w.length > 2));
      
      const intersection = new Set([...words1].filter(w => words2.has(w)));
      const union = new Set([...words1, ...words2]);
      
      return union.size === 0 ? 0 : intersection.size / union.size;
    };

    // Apply duplicate penalties (compare each item against higher-scored items)
    for (let i = 0; i < scored.length; i++) {
      const currentItem = scored[i];
      const currentAdvice = String(currentItem.advice || '');
      
      let maxSimilarity = 0;
      for (let j = 0; j < i; j++) {
        const otherItem = scored[j];
        const otherAdvice = String(otherItem.advice || '');
        
        // Only compare if other item has higher or equal score
        if ((otherItem.ltrScore ?? 0) >= (currentItem.ltrScore ?? 0)) {
          const similarity = jaccardSimilarity(currentAdvice, otherAdvice);
          maxSimilarity = Math.max(maxSimilarity, similarity);
        }
      }
      
      // Apply penalty based on highest similarity found
      if (maxSimilarity > 0.3) { // 30% similarity threshold
        const penalty = maxSimilarity * 0.5; // Scale penalty by similarity
        currentItem.ltrScore = (currentItem.ltrScore ?? 0) - penalty;
      }
    }

    return scored.sort((a,b)=> {
      // Primary sort: ltrScore descending
      const scoreDiff = (b.ltrScore ?? 0) - (a.ltrScore ?? 0);
      if (Math.abs(scoreDiff) > 0.0001) return scoreDiff; // Significant score difference
      
      // Secondary sort: category alphabetically for consistency
      const catA = a.category || a.categories?.[0] || 'zzz';
      const catB = b.category || b.categories?.[0] || 'zzz';
      const catDiff = catA.localeCompare(catB);
      if (catDiff !== 0) return catDiff;
      
      // Tertiary sort: advice length (shorter first for readability)
      const lenA = (a.advice || '').length;
      const lenB = (b.advice || '').length;
      const lenDiff = lenA - lenB;
      if (lenDiff !== 0) return lenDiff;
      
      // Quaternary sort: ID for final deterministic ordering
      const idA = a.id || '';
      const idB = b.id || '';
      return idA.localeCompare(idB);
    });
  }
}

// ============================
// Main Suggestions Service
// ============================
class SuggestionsService {
  private trialManager: TrialManager;
  private orchestrator: AnalysisOrchestrator;
  private adviceEngine: AdviceEngine;
  private _initPromise: Promise<void> | null = null;
  private _nliInitPromise: Promise<void> | null = null;

  constructor() {
    this.trialManager = new TrialManager();
    this.orchestrator = new AnalysisOrchestrator(dataLoader);
    this.adviceEngine = new AdviceEngine(dataLoader);
    
    // Add data loader aliases for file name alignment
    this.setupDataLoaderAliases();
    
    // Capture initialization promise to prevent unhandled rejections
    this._initPromise = this.initializeWithDataValidation().catch(err => {
      logger.error('Init validation failed', { err: String(err) });
    });
  }

  private async ensureNLIReady(): Promise<void> {
    if (ENV_CONTROLS.DISABLE_NLI) return;
    if (nliLocal.ready) return;
    if (!this._nliInitPromise) {
      this._nliInitPromise = nliLocal.init().catch(() => {
        logger.warn('NLI initialization failed, using rules-only fallback');
      });
    }
    await this._nliInitPromise;
  }

  private setupDataLoaderAliases(): void {
    // Handle different file naming conventions
    try {
      // Alias attachment_tone_weights to attachment_learning if needed
      if (!dataLoader.get('attachment_tone_weights') && dataLoader.get('attachment_learning')) {
        (dataLoader as any).alias('attachment_tone_weights', 'attachment_learning');
      }
      // Alias weight_modifiers to weight_multipliers if needed  
      if (!dataLoader.get('weight_modifiers') && dataLoader.get('weight_multipliers')) {
        (dataLoader as any).alias('weight_modifiers', 'weight_multipliers');
      }
    } catch (error) {
      logger.warn('Data loader alias setup failed', { error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async initializeWithDataValidation(): Promise<void> {
    try {
      await ensureDataLoaded();
      logger.info('SuggestionsService initialized with all JSON dependencies validated');
    } catch (error) {
      logger.error('SuggestionsService initialization failed:', error);
      throw error;
    }
  }

  private async ensureDataLoaded(): Promise<void> {
    await ensureDataLoaded();
  }

  // ===== Strict JSON Dependency Validation =====
  private validateCriticalDependencies(): void {
    const criticalDependencies = [
      { key: 'therapyAdvice', name: 'therapy_advice.json' },
      { key: 'toneBucketMapping', name: 'tone_bucket_mapping.json' },
      { key: 'guardrailConfig', name: 'guardrail_config.json' },
      { key: 'profanityLexicons', name: 'profanity_lexicons.json' },
      { key: 'contextClassifier', name: 'context_classifier.json' },
      { key: 'weightModifiers', name: 'weight_modifiers.json' }
    ];

    const missingDependencies: string[] = [];

    for (const { key, name } of criticalDependencies) {
      const data = dataLoader.get(key);
      if (!data) {
        missingDependencies.push(name);
      }
    }

    if (missingDependencies.length > 0) {
      throw new Error(`Critical JSON dependencies missing: ${missingDependencies.join(', ')}. Suggestions service cannot operate without these files.`);
    }

    // Validate data structure integrity
    const therapyAdvice = dataLoader.get('therapyAdvice');
    if (!therapyAdvice || !Array.isArray(therapyAdvice)) {
      throw new Error('therapy_advice.json is malformed - expected array of advice items');
    }

    if (therapyAdvice.length === 0) {
      throw new Error('therapy_advice.json is empty - no advice items found');
    }

    const toneBucketMapping = dataLoader.get('toneBucketMapping');
    if (!toneBucketMapping?.toneBuckets) {
      throw new Error('tone_bucket_mapping.json is malformed - missing toneBuckets configuration');
    }

    logger.info('All critical JSON dependencies validated successfully');
  }

  // ===== Comprehensive Guardrails Implementation =====
  private applyAdvancedGuardrails(suggestions: any[], originalText: string, analysis: any): any[] {
    logger.info('Applying advanced guardrails and profanity filtering...');
    
    const guardrailConfig = dataLoader.get('guardrailConfig');
    const profanityLexicons = dataLoader.get('profanityLexicons');
    
    // Strict JSON dependency enforcement - no fallbacks
    if (!guardrailConfig) {
      throw new Error('Critical dependency missing: guardrail_config.json not loaded');
    }
    
    if (!profanityLexicons) {
      throw new Error('Critical dependency missing: profanity_lexicons.json not loaded');
    }

    // Initialize guardrail counters for better visibility
    const guardrailCounters = {
      profanity: 0,
      blockedPattern: 0,
      contextInappropriate: 0,
      alertContextUnsafe: 0,
      softenerRequirements: 0,
      intensityGuardrails: 0,
      total: suggestions.length
    };

    const filteredSuggestions = suggestions.filter(suggestion => {
      // 1. Profanity filtering (with targeting awareness)
      const is2P = analysis?.secondPerson?.hasSecondPerson || 
                   (Array.isArray(analysis?.entities) && analysis.entities.some((e:any)=>e.label==='PRON_2P'));
      if (this.containsProfanity(suggestion.advice, profanityLexicons, is2P)) {
        logger.warn(`Suggestion filtered for profanity: ${suggestion.id}`);
        guardrailCounters.profanity++;
        return false;
      }

      // 2. Blocked pattern checking
      if (this.matchesBlockedPattern(suggestion.advice, guardrailConfig.blockedPatterns || [])) {
        logger.warn(`Suggestion filtered for blocked pattern: ${suggestion.id}`);
        guardrailCounters.blockedPattern++;
        return false;
      }

      // 3. Context appropriateness
      if (!this.checkContextAppropriate(suggestion, analysis)) {
        logger.warn(`Suggestion filtered for context inappropriateness: ${suggestion.id}`);
        guardrailCounters.contextInappropriate++;
        return false;
      }

      // 4. Safety threshold checking
      if (analysis.toneBuckets?.primary === 'alert' && !this.isSafeForAlertContext(suggestion)) {
        logger.warn(`Suggestion filtered for alert context safety: ${suggestion.id}`);
        guardrailCounters.alertContextUnsafe++;
        return false;
      }

      // 5. Enhanced guardrails: Softener requirement checks
      if (!this.passesSoftenerRequirements(suggestion, analysis, guardrailConfig)) {
        logger.warn(`Suggestion filtered for softener requirements: ${suggestion.id}`);
        guardrailCounters.softenerRequirements++;
        return false;
      }

      // 6. Enhanced guardrails: Intensity-based safety checks
      if (!this.passesIntensityGuardrails(suggestion, analysis, guardrailConfig)) {
        logger.warn(`Suggestion filtered for intensity guardrails: ${suggestion.id}`);
        guardrailCounters.intensityGuardrails++;
        return false;
      }

      return true;
    });

    // Log detailed guardrail counters for better visibility
    const filteredCount = guardrailCounters.total - filteredSuggestions.length;
    logger.info(`Guardrails applied`, { 
      poolSize: suggestions.length, 
      rankedSize: filteredSuggestions.length,
      filteredCount,
      reasons: {
        profanity: guardrailCounters.profanity,
        blockedPattern: guardrailCounters.blockedPattern,
        contextInappropriate: guardrailCounters.contextInappropriate,
        alertContextUnsafe: guardrailCounters.alertContextUnsafe,
        softenerRequirements: guardrailCounters.softenerRequirements,
        intensityGuardrails: guardrailCounters.intensityGuardrails
      }
    });
    return filteredSuggestions;
  }

  private passesSoftenerRequirements(suggestion: any, analysis: any, guardrailConfig: any): boolean {
    const softenerReqs = guardrailConfig?.softenerRequirements;
    if (!softenerReqs) return true;

    // Fixed field names to match analysis structure
    const intensityScore = analysis?.flags?.intensityScore ?? 0;
    const isAlertContext = analysis?.toneBuckets?.primary === 'alert';
    const hasNegation = analysis?.flags?.hasNegation ?? false;

    // Check if softeners are required based on context
    const requiresSoftener = 
      (softenerReqs.alwaysForAlert && isAlertContext) ||
      (intensityScore >= (softenerReqs.thresholdHighIntensity || 0.7)) ||
      (hasNegation && softenerReqs.requireForNegation);

    if (!requiresSoftener) return true;

    // Check if suggestion contains required softeners
    const advice = suggestion.advice?.toLowerCase() || '';
    const requiredSofteners = softenerReqs.patterns || [
      'might', 'perhaps', 'maybe', 'could', 'seems like', 'appears to', 
      'i wonder if', 'what if', 'have you considered', 'it\'s possible'
    ];

    // Use AC automaton first, then fallback to regex
    const hasSoftener = acHasCategory(advice, 'softener') || requiredSofteners.some((pattern: string) => {
      const regex = new RegExp(`\\b${pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
      return regex.test(advice);
    });

    return hasSoftener;
  }

  private passesIntensityGuardrails(suggestion: any, analysis: any, guardrailConfig: any): boolean {
    const intensityGuards = guardrailConfig?.intensityGuardrails;
    if (!intensityGuards) return true;

    // Fixed field name to match analysis structure
    const intensityScore = analysis?.flags?.intensityScore ?? 0;
    const advice = suggestion.advice?.toLowerCase() || '';

    // Block high-intensity suggestions if they contain confrontational language
    if (intensityScore >= (intensityGuards.highIntensityThreshold || 0.8)) {
      const confrontationalPatterns = intensityGuards.confrontationalPatterns || [
        'you should', 'you must', 'you need to', 'you have to', 'you always', 'you never'
      ];

      const isConfrontational = confrontationalPatterns.some((pattern: string) => {
        const regex = new RegExp(`\\b${pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
        return regex.test(advice);
      });

      if (isConfrontational) return false;
    }

    // Require gentle language for medium-high intensity
    if (intensityScore >= (intensityGuards.gentleLanguageThreshold || 0.5)) {
      const gentlePatterns = intensityGuards.gentlePatterns || [
        'feel', 'sense', 'experience', 'notice', 'gentle', 'kind', 'understanding'
      ];

      // Use AC automaton first, then fallback to regex
      const hasGentleLanguage = acHasCategory(advice, 'gentle') || gentlePatterns.some((pattern: string) => {
        const regex = new RegExp(`\\b${pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
        return regex.test(advice);
      });

      // Allow if has gentle language OR passes other safety checks
      return hasGentleLanguage || suggestion.triggerTone === 'clear';
    }

    return true;
  }

  private containsProfanity(text: string, profanityLexicons: any, isSecondPersonTargeted=false): boolean {
    const cats = profanityLexicons?.categories; // preferred shape
    const words = profanityLexicons?.words;     // legacy shape
    if (!cats && !Array.isArray(words)) return false;

    // Build patterns once per instance
    if (!(this as any)._profRegexCache) (this as any)._profRegexCache = new Map<string, RegExp>();
    const wb = (w:string)=>`(?:^|[^\\p{L}\\p{N}])(${w.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')})(?=$|[^\\p{L}\\p{N}])`;

    const list = cats
      ? cats.flatMap((c:any)=>c.triggerWords?.map((w:string)=>({w, targeting:c.targeting||'any', severity:c.severity||'med'}))||[])
      : words.map((w:string)=>({w, targeting:'any', severity:'med'}));

    for (const {w, targeting} of list) {
      let rx = (this as any)._profRegexCache.get(w);
      if (!rx) { rx = new RegExp(wb(w), 'iu'); (this as any)._profRegexCache.set(w, rx); }
      if (rx.test(text)) {
        if (targeting === 'other' && !isSecondPersonTargeted) continue;
        return true;
      }
    }
    return false;
  }

  private matchesBlockedPattern(text: string, blockedPatterns: string[]): boolean {
    if (!Array.isArray(blockedPatterns)) {
      return false;
    }

    try {
      // Use Aho-Corasick automaton for fast pattern matching
      const automaton = getOrCreateAutomaton();
      const matches = automaton.search(text);
      
      // Check if any matches are blocked patterns (only block true "blocked" patterns)
      const hasBlockedMatch = matches.some(match => match.category === 'blocked');
      
      if (hasBlockedMatch) {
        return true;
      }
    } catch (error) {
      logger.warn('Aho-Corasick failed in guardrails, falling back to regex', { error });
    }

    // Fallback to regex if automaton fails
    return blockedPatterns.some(pattern => {
      try {
        const regex = new RegExp(pattern, 'i');
        return regex.test(text);
      } catch (error) {
        logger.warn(`Invalid regex pattern: ${pattern}`);
        return false;
      }
    });
  }

  private checkContextAppropriate(suggestion: any, analysis: any): boolean {
    const analysisContext = analysis?.context?.label || 'general';
    const contextScores: ContextScores = 
      (analysis.richToneData?.context_analysis?.scores as Record<string,number> | undefined)
      ?? (analysis.context?.scores || {});
    
    const appropriate = isContextAppropriate(suggestion, analysisContext, contextScores);
    
    // Log for debugging
    logContextFilter(suggestion, analysisContext, contextScores, appropriate, logger);
    
    return appropriate;
  }

  /**
   * Central NLI Advice-Message Fit Gate
   * Checks entailment between user message and therapy advice hypothesis
   */
  private async nliAdviceFit(text: string, advice: any, ctx: string): Promise<FitResult> {
    // Ensure NLI is ready before use
    await this.ensureNLIReady();
    
    if (!nliLocal.ready) {
      return { ok: true, entail: 0, contra: 0, reason: 'nli_disabled' };
    }

    try {
      // Get context-specific thresholds with environment variable fallbacks
      const evaluationTones = dataLoader.get('evaluationTones') || {};
      const nliThresholds = evaluationTones.nli_thresholds || {};
      const contextThresholds = nliThresholds[ctx] || nliThresholds.default || {};
      
      const entail_min = contextThresholds.entail_min ?? ENV_CONTROLS.NLI_ENTAIL_MIN_DEFAULT;
      const contra_max = contextThresholds.contra_max ?? ENV_CONTROLS.NLI_CONTRA_MAX_DEFAULT;
      
      // Generate hypothesis for the advice
      const hypothesis = hypothesisForAdvice(advice);
      
      // Check entailment
      const { entail, contra } = await nliLocal.score(text, hypothesis);
      
      // Determine if advice fits
      const ok = entail >= entail_min && contra <= contra_max;
      
      return { 
        ok, 
        entail, 
        contra, 
        reason: ok ? 'nli_pass' : 'nli_fail' 
      };
    } catch (error) {
      logger.warn('NLI advice fit check failed', { 
        error: error instanceof Error ? error.message : String(error),
        adviceId: advice?.id 
      });
      
      // Fail open - allow advice if NLI check fails
      return { ok: true, entail: 0, contra: 0, reason: 'nli_error' };
    }
  }

  /**
   * Batch NLI processing for major performance improvement
   */
  private async batchNLIAdviceFit(text: string, advicePool: any[], ctx: string): Promise<any[]> {
    await this.ensureNLIReady();
    
    if (!nliLocal.ready) {
      // If NLI disabled, mark all as passing and return
      return advicePool.map(advice => {
        (advice as any).__nli = { ok: true, entail: 0, contra: 0, reason: 'nli_disabled' };
        return advice;
      });
    }

    try {
      const nliChecked: any[] = [];
      const NLI_MAX = Math.min(ENV_CONTROLS.NLI_MAX_ITEMS, advicePool.length);
      const nliPool = advicePool.slice(0, NLI_MAX);
      
      // Get context-specific thresholds with environment variable fallbacks
      const evaluationTones = dataLoader.get('evaluationTones') || {};
      const nliThresholds = evaluationTones.nli_thresholds || {};
      const contextThresholds = nliThresholds[ctx] || nliThresholds.default || {};
      
      const entail_min = contextThresholds.entail_min ?? ENV_CONTROLS.NLI_ENTAIL_MIN_DEFAULT;
      const contra_max = contextThresholds.contra_max ?? ENV_CONTROLS.NLI_CONTRA_MAX_DEFAULT;
      
      // Process in batches for performance
      const BATCH_SIZE = ENV_CONTROLS.NLI_BATCH_SIZE;
      for (let i = 0; i < nliPool.length; i += BATCH_SIZE) {
        const batch = nliPool.slice(i, i + BATCH_SIZE);
        
        // Generate hypotheses using memoization
        const hypotheses = batch.map(advice => getMemoizedHypothesis(advice));
        const premises = Array(batch.length).fill(text);
        
        // Batch score with timeout protection
        const timeoutMs = ENV_CONTROLS.NLI_TIMEOUT_MS;
        try {
          const batchResult = await Promise.race([
            nliLocal.scoreBatch(premises, hypotheses),
            new Promise<any>((_, reject) => 
              setTimeout(() => reject(new Error('Batch NLI timeout')), timeoutMs)
            )
          ]);
          
          // Process batch results
          batch.forEach((advice, idx) => {
            const entail = batchResult.entail[idx];
            const contra = batchResult.contra[idx];
            const ok = entail >= entail_min && contra <= contra_max;
            
            if (ok) {
              (advice as any).__nli = { ok, entail, contra, reason: 'nli_batch' };
              nliChecked.push(advice);
            } else {
              logger.debug('NLI batch rejected advice', {
                id: advice.id,
                entail,
                contra,
                ctx
              });
            }
          });
          
        } catch (error) {
          logger.warn('NLI batch failed', { 
            error: error instanceof Error ? error.message : String(error),
            batchSize: batch.length
          });
          
          // Fail open for this batch
          batch.forEach(advice => {
            (advice as any).__nli = { ok: true, entail: 0, contra: 0, reason: 'nli_batch_error' };
            nliChecked.push(advice);
          });
        }
      }
      
      // Add remaining items without NLI (they pass through)
      const remaining = advicePool.slice(NLI_MAX);
      remaining.forEach(advice => {
        (advice as any).__nli = { ok: true, entail: 0, contra: 0, reason: 'nli_skipped' };
        nliChecked.push(advice);
      });
      
      logger.info('Batch NLI processing completed', {
        inputSize: advicePool.length,
        nliProcessed: NLI_MAX,
        passed: nliChecked.length,
        ctx
      });
      
      return nliChecked;
      
    } catch (error) {
      logger.error('Batch NLI processing failed', {
        error: error instanceof Error ? error.message : String(error)
      });
      
      // Fail open - return all advice with default NLI status
      return advicePool.map(advice => {
        (advice as any).__nli = { ok: true, entail: 0, contra: 0, reason: 'nli_system_error' };
        return advice;
      });
    }
  }

  private isSafeForAlertContext(suggestion: any): boolean {
    // Additional safety checks for high-alert contexts
    if (!suggestion.advice) return false;
    
    const advice = suggestion.advice.toLowerCase();
    
    // Avoid suggestions that might escalate conflict
    const escalationPatterns = [
      'you should',
      'you need to',
      'you must',
      'you have to',
      'you always',
      'you never'
    ];
    
    if (escalationPatterns.some(pattern => advice.includes(pattern))) {
      return false;
    }

    // Require de-escalation keywords for alert contexts
    const deEscalationKeywords = [
      'consider',
      'might',
      'perhaps',
      'could',
      'gentle',
      'calm',
      'peaceful',
      'understanding',
      'patience'
    ];
    
    return deEscalationKeywords.some(keyword => advice.includes(keyword));
  }

  // ===== Public API =====
  async generateAdvancedSuggestions(
    text: string,
    context: string = 'general',
    userProfile?: any,
    options: {
      maxSuggestions?: number;
      targetEmotion?: string;
      relationshipStage?: string;
      conflictLevel?: 'low' | 'medium' | 'high';
      attachmentStyle?: string;
      userId?: string;
      userEmail?: string;
      fullToneAnalysis: ToneResponse; // must be provided
      isNewUser?: boolean;
    } = {} as any
  ): Promise<SuggestionAnalysis> {

    // Ensure initialization completes before processing
    if (this._initPromise) {
      await this._initPromise;
    }

    const {
      maxSuggestions = 5,
      attachmentStyle = 'secure',
      userId = 'anonymous',
      userEmail,
      fullToneAnalysis
    } = options;

    if (!fullToneAnalysis) {
      throw new Error('Missing Coordinator analysis: options.fullToneAnalysis is required');
    }

    await this.ensureDataLoaded();

    // TODO: If we want "degraded mode", change ensureDataLoaded to warn but not throw,
    // and gate the features that require the missing JSONs.
    
    // Critical dependencies already validated in initialization

    const trialStatus = await this.trialManager.getTrialStatus(userId, userEmail);
    if (!trialStatus?.hasAccess) throw new Error('Trial expired or access denied');
    const tier = this.trialManager.resolveTier(trialStatus);

    // Check cache for analysis first
    let analysis = performanceCache.getCachedAnalysis(text, context, attachmentStyle);
    
    if (!analysis) {
      // 1) spaCy + local analyzer (no LLM) - Cache miss, perform analysis
      analysis = await this.orchestrator.analyze(
        text,
        null,                 // no providedTone; Coordinator is source of truth
        attachmentStyle,
        context,
        fullToneAnalysis
      );
      
      // Cache the analysis result
      performanceCache.setCachedAnalysis(text, analysis, context, attachmentStyle);
      logger.info('Analysis cached', { 
        userId: options.userId || 'anonymous',
        textLength: text.length, 
        context: context, 
        attachment: attachmentStyle 
      });
    } else {
      logger.info('Analysis cache hit', { 
        userId: options.userId || 'anonymous',
        textLength: text.length, 
        context: context, 
        attachment: attachmentStyle 
      });
    }

    // Pipeline Step 1: Normalize tone to bucket immediately after analysis
    const contextLabel = context || analysis.context?.label || 'general';

    // Normalize tone → Bucket (toneKeyNorm) - prefer Coordinator ui_tone
    const uiTone = analysis.richToneData?.ui_tone as 'clear'|'caution'|'alert' | undefined;
    const uiDist = analysis.richToneData?.ui_distribution as {clear:number;caution:number;alert:number} | undefined;

    const toneKeyNorm = uiTone ?? (() => {
      const t = (analysis.tone.classification || '').toLowerCase();
      if (t==='clear'||t==='caution'||t==='alert') return t as 'clear' | 'caution' | 'alert';
      if (['positive','supportive','neutral'].includes(t)) return 'clear';
      if (['negative','angry','frustrated','safety_concern'].includes(t)) return 'alert';
      return 'caution';
    })();

    // Pipeline Step 2: Use Coordinator buckets or fallback to computed buckets
    const bucket = uiDist
      ? { primary: (Object.entries(uiDist).sort((a,b)=>b[1]-a[1])[0][0]), dist: uiDist }
      : this.adviceEngine.resolveToneBucket(toneKeyNorm, contextLabel, analysis.flags.intensityScore, (analysis as any).semanticBackbone);

    (analysis as any).toneBuckets = bucket;

    // Generate cache key for suggestions - include Coordinator UI fields for stability
    const analysisKey = JSON.stringify({
      tone: analysis.tone,
      uiTone: analysis.richToneData?.ui_tone,
      uiDist: analysis.richToneData?.ui_distribution,
      ctx: analysis.context.label,
      flags: analysis.flags
    });
    
    // Check cache for suggestions
    let suggestions = performanceCache.getCachedSuggestions(analysisKey, maxSuggestions, tier);
    
    if (suggestions) {
      logger.info('Suggestions cache hit', { count: suggestions.length, tier, maxSuggestions });
      
      // Return cached suggestions with proper format including toneBuckets
      return {
        success: true,
        tier,
        original_text: text,
        context,
        suggestions,
        analysis: {
          tone: analysis.tone,
          mlGenerated: analysis.mlGenerated,
          context: analysis.context,
          flags: analysis.flags,
          toneBuckets: (analysis as any).toneBuckets // Use the computed toneBuckets
        },
        analysis_meta: {
          complexity_score: this.calculateComplexity(text),
          emotional_intensity: this.calculateEmotionalIntensity(text),
          clarity_level: this.calculateClarity(text),
          empathy_present: this.detectEmpathy(text),
          potential_triggers: this.identifyTriggers(text),
          recommended_approach: this.recommendApproach(context, options.conflictLevel || 'low')
        },
        metadata: {
          attachmentStyle,
          timestamp: new Date().toISOString(),
          version: '4.0.0'
        } as any,
        trialStatus
      };
    }

    // Cache miss - continue with full processing
    logger.info('Suggestions cache miss - performing full processing');

    const intensityScore = analysis.flags.intensityScore;

    // 2) Retrieve (hybrid) - now with enhanced query including Coordinator signals
    const desired = Math.max(10, (options.maxSuggestions ?? 6) * 20);
    const pool = await hybridRetrieve(text, contextLabel, toneKeyNorm, analysis, desired);
    logger.info('Hybrid retrieval completed', { 
      userId: options.userId || 'anonymous',
      poolSize: pool.length, 
      context: contextLabel, 
      tone: toneKeyNorm 
    });

    // TEMPORARY: Add direct fallback when hybrid search fails
    if (pool.length === 0) {
      logger.info('Hybrid retrieval returned 0 results, trying direct fallback');
      const corpus = getAdviceCorpus();
      const directMatches = corpus.filter((item: any) => {
        // Use attachment-aware tone matching when attachment data is available
        const matchesTone = attachmentStyle 
          ? matchesToneClassificationWithAttachment(item, toneKeyNorm, attachmentStyle)
          : matchesToneClassification(item, toneKeyNorm);
        const matchesContext = item.contexts && item.contexts.includes(contextLabel);
        const matchesAttachment = item.attachmentStyles && item.attachmentStyles.includes(attachmentStyle);
        return matchesTone || matchesContext || matchesAttachment;
      }).slice(0, 10); // Take first 10 matches
      
      logger.info('Direct fallback completed', { 
        directMatchesFound: directMatches.length, 
        corpusSize: corpus.length,
        searchCriteria: { toneKeyNorm, contextLabel, attachmentStyle, 
                          attachmentAware: !!attachmentStyle }
      });
      
      // Use direct matches if found
      if (directMatches.length > 0) {
        logger.info('Using direct matches as fallback');
        pool.push(...directMatches);
      }
    }

    // 3) Guardrails / contraindications
    const safePool = applyContraindications(pool, analysis.flags);
    logger.info('Contraindications applied', { safePoolSize: safePool.length, originalPoolSize: pool.length });

    // 3.5) NLI Advice–Message Fit Gate (Batched for Performance)
    const nliChecked = await this.batchNLIAdviceFit(text, safePool, contextLabel);
    logger.info('NLI fit gate applied', { 
      nliCheckedSize: nliChecked.length, 
      safePoolSize: safePool.length,
      nliReady: nliLocal.ready 
    });

    // 4) Apply comprehensive guardrails and profanity filtering
    const guardedPool = this.applyAdvancedGuardrails(nliChecked, text, analysis);
    logger.info('Advanced guardrails applied', { guardedPoolSize: guardedPool.length, nliCheckedSize: nliChecked.length });

    // 5) Attachment personalization
    const personalized = applyAttachmentOverrides(guardedPool, attachmentStyle);
    logger.info('Attachment overrides applied', { personalizedSize: personalized.length, guardedPoolSize: guardedPool.length });

    // ✅ NEW: Enhanced user intent detection - combine detected + Coordinator intents
    const detectedIntents = detectUserIntents(text);
    const coordinatorIntents = (fullToneAnalysis as any)?.intents || [];
    const userIntents = [...new Set([...detectedIntents, ...coordinatorIntents])]; // Union unique intents
    logger.info('User intents detected', { 
      textLength: text.length, 
      detectedIntents,
      coordinatorIntents,
      combinedIntents: userIntents,
      intentCount: userIntents.length 
    });

    // 6) Rank (JSON-weighted) - now with intent-based scoring and learning signals
    const ranked = this.adviceEngine.rank(personalized, {
      baseConfidence: analysis.tone.confidence,
      toneKey: toneKeyNorm,
      contextLabel,
      attachmentStyle,
      hasNegation: analysis.flags.hasNegation,
      hasSarcasm: analysis.flags.hasSarcasm,
      intensityScore,
      phraseEdgeHits: Array.isArray(analysis.flags.phraseEdgeHits) ? analysis.flags.phraseEdgeHits : [],
      userPref: dataLoader.get('userPreference'),
      tier,
      secondPerson: analysis.secondPerson,
      contextScores: (analysis.richToneData?.context_analysis?.scores as Record<string,number> | undefined) ?? (analysis.context?.scores || {}),
      categories: fullToneAnalysis?.categories || [],
      userIntents, // ✅ NEW: Pass detected user intents for intent-based scoring
      learningSignals: analysis.learningSignals // ✅ NEW: Pass learning signals for communication pattern bonus scoring
    });
    
    // ✅ NEW: Apply NLI signals to ranking scores (not just gating)
    for (const it of ranked) {
      const nli = (it as any).__nli;
      if (!nli) continue;
      
      // Guard against flapping: skip shaping for barely-passed items
      const nliDelta = nli.entail - nli.contra;
      if (Math.abs(nliDelta) < 0.05) {
        // Tiny delta; skip shaping to keep stability
        continue;
      }
      
      // Small, bounded shaping - favor items the transformers.js NLI says "fit" best
      it.ltrScore += Math.max(-0.4, Math.min(0.4, nliDelta * 0.6));
    }
    logger.info('Ranking completed', { rankedSize: ranked.length, personalizedSize: personalized.length });

    // ✅ NEW: Integrate micro-advice from adviceIndex
    const enrichedSuggestions = await this.buildEnhancedSuggestions({
      detectedRequestCtx: contextLabel,
      uiTone: toneKeyNorm,
      classifierCtxScores: (analysis.richToneData?.context_analysis?.scores as Record<string,number> | undefined) ?? (analysis.context?.scores || {}),
      phraseEdgeCategories: Array.isArray(analysis.flags.phraseEdgeHits) ? analysis.flags.phraseEdgeHits : [],
      rewriteCandidates: ranked.map(r => ({
        type: 'rewrite' as const,
        id: r.id || String(Math.random()),
        text: r.advice || r.text || '',
        score: r.ltrScore || 0.5,
        reason: r.reason || 'rewrite suggestion',
        confidence: r.confidence || 0.5,
        category: r.category || 'communication',
        priority: r.priority || 1,
        context_specific: r.context_specific || false,
        attachment_informed: r.attachment_informed || false
      })),
      attachmentStyle,
      userId: userId || 'anonymous',
      totalCap: Math.max(3, Math.min(10, maxSuggestions)),
      featureFlags: { SUGGESTIONS_ENABLE_ADVICE: true }
    });
    logger.info('Enhanced suggestions with micro-advice completed', { 
      enhancedCount: enrichedSuggestions.length, 
      originalRankedSize: ranked.length 
    });

    // Use enriched suggestions instead of ranked for the rest of the pipeline
    const rankedForPipeline = enrichedSuggestions.map(s => ({
      ...s,
      ltrScore: s.score,
      advice: s.type === 'micro_advice' ? s.advice : s.text
    }));

    // Category guard to avoid near-duplicates
    const seenCats = new Set<string>();
    const rankedDedup = rankedForPipeline.filter((it: any) => {
      const cat = (it.category || 'general').toLowerCase();
      if (seenCats.has(cat)) return false;
      seenCats.add(cat);
      return true;
    });

    // 7) Diversity pick
    const diversifyK = Math.max(1, Math.min(20, options.maxSuggestions ?? 6));
    let picked = diversify(rankedDedup, diversifyK, 0.87);
    logger.info('Diversity pick completed', { pickedSize: picked.length, targetMax: Math.max(3, Math.min(10, maxSuggestions)) });

    // Adjust for new users: provide fewer, more general suggestions
    // DISABLED: We want full suggestions even during learning phase
    // if (options.isNewUser) {
    //   const originalCount = picked.length;
    //   picked = picked.slice(0, Math.max(2, Math.floor(picked.length * 0.6))); // Reduce by 40%
    //   logger.info('New user adjustment applied', { originalCount, newCount: picked.length, isNewUser: true });
    // }
    
    // Keep full suggestions during learning phase - attachment style refinement happens over 7 days
    logger.info('Suggestions generation completed', { 
      finalCount: picked.length, 
      isNewUser: options.isNewUser,
      attachmentStyle,
      note: 'Full suggestions provided during learning phase'
    });

    // 8) Calibrate confidence per context
    const calibrated = picked.map(it => ({
      ...it,
      __calib: calibrate(it.ltrScore || 0.5, contextLabel)
    }));

    // Enforce per-context confidence floors (load from evaluation_tones.json if present)
    const evalTones = dataLoader.get('evaluationTones') || {};
    const minConfByCtx = (evalTones.min_confidence && evalTones.min_confidence[contextLabel])
      || evalTones.min_confidence_default
      || 0.55; // reasonable default if json missing

    // Keep only strong items first; if none pass, keep the top 1
    let strong = calibrated
      .filter(it => (it.__calib ?? 0) >= minConfByCtx)
      // deterministic by calibrated conf then ltrScore
      .sort((a,b) => (b.__calib - a.__calib) || (b.ltrScore - a.ltrScore));
    if (strong.length === 0 && calibrated.length > 0) {
      strong = [ [...calibrated].sort((a,b) => (b.__calib - a.__calib) || (b.ltrScore - a.ltrScore) )[0] ];
    }

    // Decide the final K (never exceed 10, default 3)
    const topK = Math.max(1, Math.min(10, options.maxSuggestions ?? 3));
    const finalPicked = strong.slice(0, topK);

    // 9) Reuse tone bucket dist already computed from Coordinator data
    const { primary, dist } = (analysis as any).toneBuckets;

    // 10) Assemble response (no fallbacks)
    const finalSuggestions: DetailedSuggestionResult[] = finalPicked.map(({ advice, categories, id, type, __calib, ltrScore }) => ({
      id,
      text: advice, // Direct therapy advice text from therapy_advice.json
      categories,
      type: type || 'advice', // Preserve original type (micro_advice, etc.) or default to 'advice'
      confidence: __calib ?? ltrScore ?? 0.5,
      reason: 'Tone+context+attachment (NLI if enabled)',
      category: 'emotional' as const, // Match schema enum
      priority: 1,
      context_specific: true,
      attachment_informed: true,
    }));

    // Cache the final suggestions for future use
    performanceCache.setCachedSuggestions(analysisKey, finalSuggestions, topK, tier);
    logger.info('Suggestions cached', { count: finalSuggestions.length, tier, maxSuggestions });

    return {
      success: true,
      tier,
      original_text: text,
      context,
      suggestions: finalSuggestions,
      analysis: {
        tone: analysis.tone,
        mlGenerated: analysis.mlGenerated,
        context: analysis.context,
        flags: {
          hasNegation: analysis.flags.hasNegation,
          hasSarcasm: analysis.flags.hasSarcasm,
          intensityScore: analysis.flags.intensityScore,
          phraseEdgeHits: Array.isArray(analysis.flags.phraseEdgeHits) ? analysis.flags.phraseEdgeHits : []
        },
        toneBuckets: { primary, dist }
      },
      analysis_meta: {
        complexity_score: this.calculateComplexity(text),
        emotional_intensity: this.calculateEmotionalIntensity(text),
        clarity_level: this.calculateClarity(text),
        empathy_present: this.detectEmpathy(text),
        potential_triggers: this.identifyTriggers(text),
        recommended_approach: this.recommendApproach(context, options.conflictLevel || 'low')
      },
      metadata: {
        attachmentStyle,
        timestamp: new Date().toISOString(),
        version: '4.0.0'
      },
      trialStatus
    };
  }

  // ===== Legacy adapter (still no fallbacks) =====
  async generate(params: {
    text: string;
    toneHint?: string;
    styleHint?: string;
    features?: string[];
    meta?: any;
    analysis?: { classification: string; confidence: number } | null;
    fullToneAnalysis?: ToneResponse; // Add this required parameter
  }) {
    const { text, styleHint = 'secure', meta = {}, analysis = null, fullToneAnalysis } = params;
    
    if (!fullToneAnalysis) {
      throw new Error('Legacy generate method requires fullToneAnalysis parameter');
    }
    
    const result = await this.generateAdvancedSuggestions(
      text,
      'general',
      meta.userProfile,
      {
        attachmentStyle: styleHint || 'secure',
        userId: meta.userId || 'anonymous',
        fullToneAnalysis
      }
    );

    return {
      quickFixes: result.suggestions.slice(0, 3).map(item => ({
        text: item.text, // Use the therapy advice text directly
        confidence: item.confidence
      })),
      advice: result.suggestions.slice(0, 5).map(item => ({
        advice: item.text,
        reasoning: item.reason,
        confidence: item.confidence
      })),
      evidence: result.analysis?.flags?.phraseEdgeHits || [],
      extras: {
        tone: result.analysis?.tone,
        context: result.analysis?.context,
        tier: result.tier
      }
    };
  }

  // ===== Enhanced Suggestions with Micro-Advice Integration =====
  private async buildEnhancedSuggestions(input: {
    detectedRequestCtx: string;
    uiTone: 'clear'|'caution'|'alert';
    classifierCtxScores: Record<string, number>;
    phraseEdgeCategories: string[];
    rewriteCandidates: Array<{
      type: 'rewrite';
      id: string;
      text: string;
      score: number;
      reason: string;
      confidence: number;
      category: string;
      priority: number;
      context_specific: boolean;
      attachment_informed: boolean;
    }>;
    attachmentStyle: string;
    userId: string;
    totalCap?: number;
    featureFlags?: Record<string, boolean>;
  }) {
    const {
      detectedRequestCtx,
      uiTone,
      classifierCtxScores,
      phraseEdgeCategories = [],
      rewriteCandidates,
      attachmentStyle,
      userId,
      totalCap = 8,
      featureFlags = {}
    } = input;

    // (1) fold in attachment patterns
    const communicatorProfile = new CommunicatorProfile({ userId });
    await communicatorProfile.init();
    const est = communicatorProfile.getAttachmentEstimate();
    
    const edgeHints = phraseEdgeCategories.filter(c =>
      c === 'attachment_triggers' || c === 'codependency_patterns' || c === 'independence_patterns'
    ) as Array<'attachment_triggers'|'codependency_patterns'|'independence_patterns'>;
    
    const ctxScores = foldAttachmentPatterns(
      classifierCtxScores,
      {
        confidence: est.confidence ?? 0,
        scores: {
          anxious: est.scores?.anxious ?? 0,
          avoidant: est.scores?.avoidant ?? 0,
          disorganized: est.scores?.disorganized ?? 0,
          secure: est.scores?.secure ?? 0,
        }
      },
      edgeHints
    );

    // (2) micro-advice from adviceIndex
    let adviceItems: any[] = [];
    if (featureFlags.SUGGESTIONS_ENABLE_ADVICE !== false) {
      adviceItems = await getAdviceCandidates({
        requestCtx: detectedRequestCtx,
        ctxScores,
        triggerTone: uiTone,
        limit: 8,
        tryGetAttachmentEstimate: () => ({
          primary: est.scores && est.scores.anxious > Math.max(est.scores.avoidant, est.scores.disorganized, est.scores.secure) ? 'anxious' :
                  est.scores && est.scores.avoidant > Math.max(est.scores.anxious, est.scores.disorganized, est.scores.secure) ? 'avoidant' :
                  est.scores && est.scores.disorganized > Math.max(est.scores.anxious, est.scores.avoidant, est.scores.secure) ? 'disorganized' : 'secure',
          confidence: est.confidence
        })
      });
    }

    // (3) map micro-advice to suggestions
    const adviceSuggestions = adviceItems.map((a: any, i: number) => ({
      type: 'micro_advice' as const,
      id: a.id,
      advice: a.advice,
      score: 0.5 - i * 0.001, // minor tiebreak; your ranker will refine
      reason: 'micro-therapy tip',
      confidence: 0.8,
      category: a.contexts?.[0] || 'communication',
      priority: 2,
      context_specific: true,
      attachment_informed: true,
      meta: {
        contexts: a.contexts,
        contextLink: a.contextLink,
        triggerTone: a.triggerTone,
        attachmentStyles: a.attachmentStyles,
        intent: a.intents,
        tags: a.tags,
        patterns: a.patterns,
        source: 'adviceIndex'
      }
    }));

    // (4) merge + rank (reuse your existing ranker)
    const merged = [...rewriteCandidates, ...adviceSuggestions].sort((a, b) => b.score - a.score);

    // (5) micro caps (guard UI density)
    const MAX_MICRO = 3, MIN_MICRO = 1;
    const micro = merged.filter(s => s.type === 'micro_advice').slice(0, MAX_MICRO);
    const nonMicro = merged.filter(s => s.type !== 'micro_advice');

    const final = [
      ...nonMicro.slice(0, totalCap - Math.max(micro.length, MIN_MICRO)),
      ...micro
    ].slice(0, totalCap);

    // (6) telemetry (optional)
    logger.debug('suggestions.merged', {
      tone: uiTone,
      ctx: detectedRequestCtx,
      topCtx: Object.entries(ctxScores).sort((a,b)=>b[1]-a[1]).slice(0,3),
      microAdviceCount: micro.length,
      patterns: {
        anxious: ctxScores['anxious.pattern'] || 0,
        avoidant: ctxScores['avoidant.pattern'] || 0,
        disorganized: ctxScores['disorganized.pattern'] || 0,
        secure: ctxScores['secure.pattern'] || 0
      },
      conf: est?.confidence ?? 0
    });

    return final;
  }

  // ===== Utility methods for analysis_meta (unchanged) =====
  private calculateComplexity(text: string): number {
    const words = Math.max(1, text.trim().split(/\s+/).length);
    const sentences = Math.max(1, text.split(/[.!?]+/).filter(Boolean).length);
    const avgWordsPerSentence = words / sentences;
    return Math.min(1, avgWordsPerSentence / 20);
  }

  private calculateEmotionalIntensity(text: string): number {
    const emotionalWords = ['love', 'hate', 'amazing', 'terrible', 'furious', 'devastated', 'thrilled'];
    const punctuation = (text.match(/[!?]/g) || []).length;
    const caps = (text.match(/[A-Z]{2,}/g) || []).length;
    let intensity = 0;
    emotionalWords.forEach(word => { if (text.toLowerCase().includes(word)) intensity += 0.2; });
    intensity += punctuation * 0.1;
    intensity += caps * 0.15;
    return Math.min(1, intensity);
  }

  private calculateClarity(text: string): number {
    const words = Math.max(1, text.trim().split(/\s+/).length);
    const vagueWords = ['maybe', 'perhaps', 'sort of', 'kind of', 'whatever'];
    let vagueCount = 0;
    vagueWords.forEach(word => { if (text.toLowerCase().includes(word)) vagueCount++; });
    return Math.max(0, 1 - (vagueCount / words * 5));
  }

  private detectEmpathy(text: string): boolean {
    const empathyMarkers = [
      'understand', 'feel', 'hear you', 'appreciate', 'see your point',
      'that makes sense', 'i can imagine', 'must be'
    ];
    return empathyMarkers.some(marker => text.toLowerCase().includes(marker));
  }

  private identifyTriggers(text: string): string[] {
    const commonTriggers = [
      { pattern: /\byou always\b/i, trigger: 'absolute language' },
      { pattern: /\byou never\b/i, trigger: 'absolute language' },
      { pattern: /\bwhat'?s wrong with you\b/i, trigger: 'personal attack' },
      { pattern: /\bstupid\b/i, trigger: 'name calling' },
      { pattern: /\bidiot\b/i, trigger: 'name calling' },
      { pattern: /\bwhatever\b/i, trigger: 'dismissiveness' },
      { pattern: /\bfine\b(?!\s+(with|by))/i, trigger: 'passive aggression' },
    ];
    return commonTriggers.filter(t => t.pattern.test(text)).map(t => t.trigger);
  }

  private recommendApproach(context: string, conflictLevel: string): string {
    if (conflictLevel === 'high') return 'validating';
    if (context === 'romantic') return 'gentle';
    if (context === 'professional') return 'direct';
    return 'exploratory';
  }
}

export const suggestionsService = new SuggestionsService();