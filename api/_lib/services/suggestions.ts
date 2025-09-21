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
import { MLAdvancedToneAnalyzer } from './toneAnalysis';
import { processWithSpacy, processWithSpacySync } from './spacyBridge';
import { spacyClient } from './spacyClient';
import type {
  TherapyAdvice,
  ContextClassifier,
  ToneTriggerWord,
  NegationPattern,
  SarcasmIndicator,
  IntensityModifier,
  PhraseEdge,
  ToneBucketMapping,
  WeightModifier,
  GuardrailConfig,
  ProfanityLexicon,
  AttachmentOverride,
  LearningSignal,
  EvaluationTone,
  UserPreference
} from '../types/dataTypes';
import type { ToneResponse } from '../schemas/toneRequest';
import { adjustToneByAttachment } from './utils/attachmentToneAdjust';
import { matchSemanticBackbone, applySemanticBias, type SemanticBackboneResult } from './utils/semanticBackbone';
import { isContextAppropriate, logContextFilter, getContextLinkBonus, type ContextScores } from './contextAnalysis';

// ---- weight-mod fallback resolver (exact → alias → family → general → code_default)
const DISABLE_WEIGHT_FALLBACKS = process.env.DISABLE_WEIGHT_FALLBACKS === '1';
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
  private readonly maxCacheSize = 500;
  private readonly cacheExpiryMs = 30 * 60 * 1000; // 30 minutes

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
      .slice(0, Math.floor(this.maxCacheSize * 0.2)); // Remove 20% of entries
    
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

function bm25Search(query: string, limit = 200): any[] {
  let bm25 = dataLoader.get('adviceBM25');
  logger.info('bm25Search called', { 
    hasBM25: !!bm25, 
    query, 
    limit,
    bm25Type: typeof bm25
  });
  
  if (!bm25) return [];
  
  const hits = bm25.search(query, { prefix: true, fuzzy: 0.2 }).slice(0, limit);
  logger.info('BM25 search completed', { hitsCount: hits.length, query });
  
  const byId = new Map<string, any>(getAdviceCorpus().map((it:any)=>[it.id, it]));
  const result = hits.map((h:any)=>byId.get(h.id)).filter(Boolean);
  logger.info('BM25 results mapped', { finalResultCount: result.length, hitsCount: hits.length });
  
  return result;
}

function mmr(pool: any[], qVec: Float32Array | null, vecOf: (it:any)=>Float32Array|null, k=200, lambda=0.7) {
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

async function hybridRetrieve(text: string, contextLabel: string, toneKey: string, k=120) { // 120 is plenty with MMR
  const corpus = getAdviceCorpus();
  logger.info('hybridRetrieve started', { 
    corpusSize: corpus.length, 
    contextLabel, 
    toneKey, 
    text: text.substring(0, 50),
    k 
  });
  
  const query = `${text} ctx:${contextLabel} tone:${toneKey}`;
  let denseTop: any[] = [];
  let qVec: Float32Array | null = null;

  // Vector cache for performance
  const vecCache = new Map<string, Float32Array>();
  const getV = (id:string)=> vecCache.get(id) || (()=>{ const v=getVecById(id); if (v) vecCache.set(id,v); return v; })();

  const hasVecs = !!getVecById(corpus[0]?.id || '');
  logger.info('Vector check', { hasVecs, firstItemId: corpus[0]?.id });
  
  if (hasVecs && typeof (spacyClient.embed) === 'function') {
    const qArr: number[] = await spacyClient.embed(query);
    qVec = new Float32Array(qArr);
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
  const lambda = retrievalConfig?.mmrLambda?.[contextLabel] ?? 0.7;
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
    private mlAnalyzer: MLAdvancedToneAnalyzer,
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

    // Enhanced regex patterns for second-person detection
    const directPatterns = [
      /\byou\s+(are|were|will|would|can|could|should|need|have|had|do|did|don't|didn't|won't|wouldn't)\b/gi,
      /\byou['']?(re|ve|ll|d)\b/gi,
      /\byour(s?)\b/gi,
      /\byourself\b/gi
    ];

    const indirectPatterns = [
      /\bif\s+you\b/gi,
      /\bwhen\s+you\b/gi,
      /\bhave\s+you\b/gi,
      /\bdo\s+you\b/gi,
      /\bwould\s+you\b/gi,
      /\bcould\s+you\b/gi
    ];

    // Check direct targeting patterns
    for (const pattern of directPatterns) {
      const matches = text.match(pattern);
      if (matches) {
        patterns.push(`direct_${pattern.source}`);
        confidence += 0.6 * matches.length;
        if (targeting === 'none') targeting = 'direct';
      }
    }

    // Check indirect targeting patterns
    for (const pattern of indirectPatterns) {
      const matches = text.match(pattern);
      if (matches) {
        patterns.push(`indirect_${pattern.source}`);
        confidence += 0.3 * matches.length;
        if (targeting === 'none') targeting = 'indirect';
      }
    }

    // Check for imperatives (commands) which often imply second person
    const imperativePatterns = [
      /^\s*[A-Z][a-z]+\s+(your|the|this|that)/i, // "Take your time"
      /^\s*[A-Z][a-z]+\s+(to|with|for|about)/i,  // "Talk to someone"
      /^\s*(try|consider|think|remember|focus|stop|start|keep|let|make|take|give|find|ask)\b/gi
    ];

    for (const pattern of imperativePatterns) {
      const matches = text.match(pattern);
      if (matches) {
        patterns.push(`imperative_${pattern.source}`);
        confidence += 0.4 * matches.length;
        if (targeting === 'none') targeting = 'indirect';
      }
    }

    confidence = Math.min(1.0, confidence);
    const hasSecondPerson = confidence > 0.2;

    return { hasSecondPerson, confidence, patterns, targeting };
  }

  async analyze(
    text: string,
    providedTone?: { classification: string; confidence: number } | null,
    attachmentStyle?: string,
    contextHint?: string,
    fullToneAnalysis?: ToneResponse | null
  ) {
    // Use spaCy bridge for processing
    const spacyResult = await processWithSpacy(text);

    // Get additional analysis data from spacyClient for intensity calculation
    const fullAnalysis = spacyClient.process(text);

    // Improved intensity with POS adv
    const advCount = (spacyResult.tokens || []).filter((t:any)=>String(t.pos).toUpperCase()==='ADV').length;
    const excl = (text.match(/!/g)||[]).length * 0.08;
    const q = (text.match(/\?/g)||[]).length * 0.04;
    const caps = (text.match(/[A-Z]{2,}/g)||[]).length * 0.12;
    const mod = fullAnalysis.intensity?.score || 0;
    const intensityScore = Math.min(1, excl + q + caps + mod + advCount*0.04);

    let toneResult = providedTone || null;
    let mlGenerated = false;
    let richToneData: any = null;

    // Priority: fullToneAnalysis > providedTone > run analysis
    if (fullToneAnalysis) {
      // Extract tone result from full analysis
      toneResult = {
        classification: fullToneAnalysis.tone,
        confidence: fullToneAnalysis.confidence
      };
      richToneData = {
        emotions: fullToneAnalysis.emotions,
        intensity: fullToneAnalysis.metadata?.analysis_depth ? fullToneAnalysis.metadata.analysis_depth : intensityScore,
        sentiment_score: fullToneAnalysis.sentiment_score || fullToneAnalysis.confidence, // Use actual sentiment score if available
        
        // 🎯 CRITICAL FIX: Use ACTUAL linguistic features from coordinator, not defaults!
        linguistic_features: fullToneAnalysis.linguistic_features || {
          formality_level: 0.5, // Fallback only if missing
          emotional_complexity: Object.keys(fullToneAnalysis.emotions?.emotions || {}).length > 0 ? 0.7 : 0.3,
          assertiveness: (fullToneAnalysis.emotions?.emotions?.anger || fullToneAnalysis.emotions?.emotions?.confident || 0) * 0.8,
          empathy_indicators: fullToneAnalysis.attachmentInsights || [],
          potential_misunderstandings: []
        },
        
        // 🎯 CRITICAL FIX: Use ACTUAL context analysis from coordinator, not defaults!
        context_analysis: fullToneAnalysis.context_analysis || {
          appropriateness_score: fullToneAnalysis.confidence,
          relationship_impact: fullToneAnalysis.ui_tone === 'alert' ? 'negative' : 
                              fullToneAnalysis.ui_tone === 'caution' ? 'neutral' : 'positive',
          suggested_adjustments: fullToneAnalysis.suggestions?.map(s => s.text) || []
        },
        
        ui_tone: fullToneAnalysis.ui_tone,
        ui_distribution: fullToneAnalysis.ui_distribution,
        evidence: fullToneAnalysis.evidence
      };
      logger.info('Using full tone analysis', { tone: toneResult.classification, ui_tone: fullToneAnalysis.ui_tone });
    } else if (!toneResult) {
      const ml = await this.mlAnalyzer.analyzeTone(
        text,
        attachmentStyle || 'secure',
        contextHint || spacyResult.context?.label || 'general',
        'general'
      );
      if (ml?.success) {
        toneResult = { classification: ml.tone.classification, confidence: ml.tone.confidence };
        mlGenerated = true;
      } else {
        // No fallback: if analyzer fails, throw — caller handles as 4xx
        throw new Error('Tone analysis unavailable');
      }
    }

    // Apply semantic backbone analysis
    const semanticThesaurus = this.loader.get('semanticThesaurus');
    const semanticResult = matchSemanticBackbone(
      text, 
      attachmentStyle || 'secure', 
      semanticThesaurus
    );

    return {
      tone: toneResult!,
      context: spacyResult.context || { label: contextHint || 'general', score: 0.5 },
      entities: fullAnalysis.entities || [],
      secondPerson: this.enhancedSecondPersonDetection(text, spacyResult, fullAnalysis),
      flags: {
        hasNegation: fullAnalysis.negation?.present || (spacyResult.deps || []).some((d:any)=>d.rel==='neg'),
        hasSarcasm: spacyResult.sarcasm?.present || false,
        intensityScore,
        phraseEdgeHits: spacyResult.phraseEdges || []
      },
      features: fullAnalysis.features || {},
      mlGenerated,
      semanticBackbone: semanticResult,
      richToneData // ← Add the rich tone analysis data
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
      actionabilityBoost: 0.1
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
    dist = { clear: clearVal/sum, caution: cautionVal/sum, alert: alertVal/sum };

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
    dist.clear = clearNum / sum;
    dist.caution = cautionNum / sum;
    dist.alert = alertNum / sum;

    const primary = (Object.entries(dist).sort((a, b) => (b[1] as number) - (a[1] as number))[0][0]) as string;
    return { primary, dist: dist as ToneBucketDistribution };
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
    
    // Apply temperature scaling: score' = score / temperature
    // Higher temperature = more uniform distribution (lower confidence)
    // Lower temperature = sharper distribution (higher confidence)
    return scores.map(score => score / temp);
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
  }): any[] {
    const W = this.currentWeights(signals.contextLabel);

    const scored = items.map((it:any) => {
      let s = 0;
      s += W.baseConfidence * (signals.baseConfidence ?? 0.8);

      // Tone match mass
      const { dist } = this.resolveToneBucket(signals.toneKey, signals.contextLabel, signals.intensityScore);
      const toneBucket = it.triggerTone || 'clear';
      const toneMatchMass = (dist as any)[toneBucket] ?? 0.33;
      s += W.toneMatch * toneMatchMass;

      // Context
      const ctxMatch = !it.contexts || it.contexts.length === 0 || it.contexts.includes(signals.contextLabel) ? 1 : 0;
      s += W.contextMatch * ctxMatch;
      
      // Context link bonus (use top 3 contexts from analysis)
      const topContexts = Object.entries(signals.contextScores || {})
        .sort((a, b) => (b[1] as number) - (a[1] as number))
        .slice(0, 3)
        .map(([ctx]) => ctx);
      const contextLinkBonus = getContextLinkBonus(it, topContexts);
      s += contextLinkBonus;

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
          // Strong boost for category matches - improves relevance significantly
          const categoryMatchBoost = 0.4 * categoryOverlap.length; // 0.4 per match
          s += categoryMatchBoost;
          
          // Log category boost for observability
          if (categoryMatchBoost > 0) {
            logger.info('Category boost applied', {
              adviceId: it.id,
              matchedCategories: categoryOverlap,
              boost: categoryMatchBoost,
              toneCategories: Array.from(therapyCategories),
              adviceCategories: Array.from(adviceCategories)
            });
          }
        }
      }

      // Actionability and brevity rewards
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
  private mlAnalyzer: MLAdvancedToneAnalyzer;
  private orchestrator: AnalysisOrchestrator;
  private adviceEngine: AdviceEngine;

  constructor() {
    this.trialManager = new TrialManager();
    this.mlAnalyzer = new MLAdvancedToneAnalyzer({ enableSmoothing: true, enableSafetyChecks: true });
    this.orchestrator = new AnalysisOrchestrator(this.mlAnalyzer, dataLoader);
    this.adviceEngine = new AdviceEngine(dataLoader);
    
    // Initialize with comprehensive JSON validation
    this.initializeWithDataValidation();
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
      if (!this.isContextAppropriate(suggestion, analysis)) {
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

    const hasSoftener = requiredSofteners.some((pattern: string) => {
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

      const hasGentleLanguage = gentlePatterns.some((pattern: string) => {
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

  private isContextAppropriate(suggestion: any, analysis: any): boolean {
    const analysisContext = analysis?.context?.label || 'general';
    const contextScores: ContextScores = analysis?.context?.scores || {};
    
    const appropriate = isContextAppropriate(suggestion, analysisContext, contextScores);
    
    // Log for debugging
    logContextFilter(suggestion, analysisContext, contextScores, appropriate, logger);
    
    return appropriate;
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
      toneAnalysisResult?: { classification: string; confidence: number } | null;
      fullToneAnalysis?: ToneResponse | null;
      isNewUser?: boolean;
    } = {}
  ): Promise<SuggestionAnalysis> {

    const {
      maxSuggestions = 5,
      attachmentStyle = 'secure',
      userId = 'anonymous',
      userEmail,
      toneAnalysisResult,
      fullToneAnalysis
    } = options;

    await this.ensureDataLoaded();

    // TODO: If we want "degraded mode", change ensureDataLoaded to warn but not throw,
    // and gate the features that require the missing JSONs.
    
    // Strict JSON dependency validation - enforce all critical data is loaded
    this.validateCriticalDependencies();

    const trialStatus = await this.trialManager.getTrialStatus(userId, userEmail);
    if (!trialStatus?.hasAccess) throw new Error('Trial expired or access denied');
    const tier = this.trialManager.resolveTier(trialStatus);

    // Check cache for analysis first
    let analysis = performanceCache.getCachedAnalysis(text, context, attachmentStyle);
    
    if (!analysis) {
      // 1) spaCy + local analyzer (no LLM) - Cache miss, perform analysis
      analysis = await this.orchestrator.analyze(
        text,
        toneAnalysisResult ?? null,
        attachmentStyle,
        context,
        fullToneAnalysis ?? null
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

    // Normalize tone → Bucket (toneKeyNorm)
    const toneKeyNorm: 'clear' | 'caution' | 'alert' = (() => {
      const t = (analysis.tone.classification || '').toLowerCase();
      if (t==='clear'||t==='caution'||t==='alert') return t as 'clear' | 'caution' | 'alert';
      if (['positive','supportive','neutral'].includes(t)) return 'clear';
      if (['negative','angry','frustrated','safety_concern'].includes(t)) return 'alert';
      return 'caution';
    })();

    // Pipeline Step 2: Seed toneBuckets early so guardrails can read it
    const { primary: bucketPrimary, dist: bucketDist } = this.adviceEngine.resolveToneBucket(
      toneKeyNorm, 
      contextLabel, 
      analysis.flags.intensityScore,
      (analysis as any).semanticBackbone
    );
    (analysis as any).toneBuckets = { primary: bucketPrimary, dist: bucketDist };

    // Generate cache key for suggestions
    // TODO: include data schema version in the cache key if JSONs change frequently.
    const analysisKey = `${JSON.stringify(analysis.tone)}:${analysis.context.label}:${JSON.stringify(analysis.flags)}`;
    
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

    // 2) Retrieve (hybrid)
    const desired = Math.max(10, (options.maxSuggestions ?? 6) * 20);
    const pool = await hybridRetrieve(text, contextLabel, toneKeyNorm, desired);
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
        const matchesTone = item.triggerTone === toneKeyNorm;
        const matchesContext = item.contexts && item.contexts.includes(contextLabel);
        const matchesAttachment = item.attachmentStyles && item.attachmentStyles.includes(attachmentStyle);
        return matchesTone || matchesContext || matchesAttachment;
      }).slice(0, 10); // Take first 10 matches
      
      logger.info('Direct fallback completed', { 
        directMatchesFound: directMatches.length, 
        corpusSize: corpus.length,
        searchCriteria: { toneKeyNorm, contextLabel, attachmentStyle }
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

    // 4) Apply comprehensive guardrails and profanity filtering
    const guardedPool = this.applyAdvancedGuardrails(safePool, text, analysis);
    logger.info('Advanced guardrails applied', { guardedPoolSize: guardedPool.length, safePoolSize: safePool.length });

    // 5) Attachment personalization
    const personalized = applyAttachmentOverrides(guardedPool, attachmentStyle);
    logger.info('Attachment overrides applied', { personalizedSize: personalized.length, guardedPoolSize: guardedPool.length });

    // 6) Rank (JSON-weighted)
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
      contextScores: analysis.context?.scores || {},
      categories: fullToneAnalysis?.categories || []
    });
    logger.info('Ranking completed', { rankedSize: ranked.length, personalizedSize: personalized.length });

    // Category guard to avoid near-duplicates
    const seenCats = new Set<string>();
    const rankedDedup = ranked.filter(it => {
      const cat = (it.category || it.categories?.[0] || 'general').toLowerCase();
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

    // 9) Build tone bucket dist for response header (from toneKeyNorm)
    const { primary, dist } = this.adviceEngine.resolveToneBucket(
      toneKeyNorm, 
      contextLabel, 
      intensityScore,
      (analysis as any).semanticBackbone
    );

    // 10) Assemble response (no fallbacks)
    const finalSuggestions = finalPicked.map(({ advice, categories, ltrScore, id, __calib }) => ({
      id,
      text: advice, // Direct therapy advice text from therapy_advice.json
      categories,
      type: 'advice' as const, // This is therapy advice, not a rewrite
      confidence: __calib ?? ltrScore ?? 0.5,
      reason: 'Therapeutic advice based on tone analysis and attachment style',
      category: 'emotional' as const, // Match schema enum
      priority: 1,
      context_specific: true,
      attachment_informed: true,
      ltrScore
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
  }) {
    const { text, styleHint = 'secure', meta = {}, analysis = null } = params;
    const result = await this.generateAdvancedSuggestions(
      text,
      'general',
      meta.userProfile,
      {
        attachmentStyle: styleHint || 'secure',
        userId: meta.userId || 'anonymous',
        toneAnalysisResult: analysis
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
      evidence: result.analysis.flags.phraseEdgeHits,
      extras: {
        tone: result.analysis.tone,
        context: result.analysis.context,
        tier: result.tier
      }
    };
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