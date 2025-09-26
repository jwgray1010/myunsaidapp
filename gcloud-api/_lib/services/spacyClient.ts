 // api/_lib/services/spacyClient.ts
// -----------------------------------------------------------------------------
// Local-only "spaCy helper" (no cloud, no Python). Lightweight heuristics
// that provide just enough NLP signal for your JSON-first tone engine:
// - tokens (text/lemma/POS + char spans)
// - sentence spans (char offsets)
// - dependency-ish negation scopes (neg -> head + subtree span)
// - cheap sarcasm/intensity/edge hits via your JSON config (precompiled)
// - context classification (JSON)
//
// Design goals:
// - Safe: input clamp, time/complexity budgets, graceful degradation
// - Fast: precompiled regexes; LRU caching; zero network
// - Compatible: preserves legacy exports + shapes used by toneAnalysis.ts
// -----------------------------------------------------------------------------

import { readFileSync } from 'fs';
import { join, resolve } from 'path';
import { env } from 'process';
import { performance } from 'node:perf_hooks';
import { logger } from '../logger';
import { tokenize, DEFAULT_STOPWORDS } from '../utils/tokenize';

const CLIENT_VERSION = '1.2.0';

// Prefer Node perf hooks; keep fallback
const now = (): number => (performance?.now?.() ?? Date.now());

function extractSecondPersonTokenSpans(tokens: SpacyToken[]) {
  const SECOND = new Set(['you','your',"you're",'ur','u','yours','yourself',"youre"]);
  const spans: Array<{start:number; end:number}> = [];
  for (const t of tokens) {
    const lem = (t.lemma || t.text || '').toLowerCase();
    if (SECOND.has(lem)) spans.push({ start: t.index, end: t.index });
  }
  spans.sort((a,b)=>a.start-b.start);
  const merged: typeof spans = [];
  for (const s of spans) {
    const last = merged[merged.length-1];
    if (last && s.start <= last.end + 1) last.end = Math.max(last.end, s.end);
    else merged.push({ ...s });
  }
  return merged;
}

// -----------------------------
// Public types (kept for compatibility)
// -----------------------------

// ---- P taxonomy / classifier types ----
export type PScoreMap = Record<string, number>;

export interface PClassification {
  p_scores: PScoreMap;          // e.g., { P031: 0.72, P044: 0.55 }
  ruleScores: PScoreMap;        // rule-only scores
  mlScores?: PScoreMap;         // zero-shot scores (if enabled)
  topP: string[];               // sorted P ids by merged score
}

export interface SpacyToken {
  text: string;
  lemma: string;
  pos: string;
  tag?: string;
  dep?: string;
  ent_type?: string;
  is_alpha: boolean;
  is_stop: boolean;
  is_punct: boolean;
  index: number;
  start?: number; // char start
  end?: number;   // char end
}

export interface SpacyEntity {
  text: string;
  label: string;
  start: number;
  end: number;
}

export interface SpacyDependency {
  text: string;     // surface text for the relation span
  relation: string; // e.g., 'neg'
  start: number;    // char start of the relation span
  end: number;      // char end of the relation span
  head?: number;    // token index of the head
  token?: number;   // token index of the dependent (neg trigger)
}

export interface ContextClassification {
  primaryContext: string;
  secondaryContext: string | null;
  allContexts: Array<{
    context: string;
    score: number;
    confidence: number;
    matchedPatterns: string[];
    description?: string;
  }>;
  confidence: number;
}

export interface NegationAnalysis {
  hasNegation: boolean;
  negations: Array<{
    negationWord: string;
    position: number; // char offset
    scope: string;    // substring window
    type: string;     // simple | contraction | absolute | complex_pattern
  }>;
  negationCount: number;
}

export interface SarcasmAnalysis {
  hasSarcasm: boolean;
  sarcasmIndicators: Array<{
    pattern: string;
    position: number; // char offset
    type: string;     // linguistic_pattern | punctuation_pattern | json_indicator
    confidence: number;
  }>;
  sarcasmScore: number;
  overallSarcasmProbability: number;
}

export interface IntensityAnalysis {
  hasIntensity: boolean;
  intensityWords: Array<{
    word: string;
    position: number;
    level: string;      // low | moderate | moderate-high | high | custom
    multiplier: number; // numeric weight
    scope: string;
  }>;
  intensityCount: number;
  overallIntensity: number;
  dominantLevel: string;
}

export interface SpacyProcessResult {
  // Compact surface for orchestrators (kept for compatibility)
  context: { label: string; score: number };
  entities: SpacyEntity[];
  negation: { present: boolean; score: number };
  sarcasm: { present: boolean; score: number };
  intensity: { score: number };
  phraseEdges: { hits: string[] };
  features: { featureCount: number };

  // Extra fields used by toneAnalysis.ts (spacyLiteSync expects these):
  tokens?: SpacyToken[];
  sents?: Array<{ start: number; end: number }>;
  deps?: Array<{ rel: string; head: number; token: number; start: number; end: number }>;
  subtreeSpan?: Record<number, { start: number; end: number }>; // by head index

  // P-code classification results
  pScores?: PScoreMap;         // merged scores above threshold
  pTop?: string[];             // ranked P ids
}

export interface SpacyFullAnalysis {
  originalText: string;
  tokens: SpacyToken[];
  entities: SpacyEntity[];
  dependencies: SpacyDependency[];
  contextClassification: ContextClassification;
  negationAnalysis: NegationAnalysis;
  sarcasmAnalysis: SarcasmAnalysis;
  intensityAnalysis: IntensityAnalysis;
  _phraseEdgeHits: string[];
  processingTimeMs: number;
  timestamp: string;
  // extras for convenience
  sents: Array<{ start: number; end: number }>;
  deps: Array<{ rel: string; head: number; token: number; start: number; end: number }>;
  subtreeSpan: Record<number, { start: number; end: number }>;
}

// Helper doc shape (local helper only, no network)
export type SpacyHelperField = 'tokens'|'sents'|'neg_scopes'|'pos_counts'|'entities';
export interface SpacyHelperDoc {
  tokens?: Array<{ text: string; lemma: string; pos: string; i: number }>;
  sents?: Array<{ start: number; end: number }>;
  neg_scopes?: Array<{ start: number; end: number; trigger: string }>;
  pos_counts?: Record<string, number>;
  entities?: SpacyEntity[];
  context?: { label: string; score: number };
  sarcasm?: { present: boolean };
}

// -----------------------------
// Implementation
// -----------------------------

type Mode = 'lite'|'balanced'|'max';

export class SpacyService {
  private dataPath: string;
  private mode: Mode;
  private budgets = { maxMillis: 60, maxChars: 2000, maxTokens: 400 };

  // caches with environment variable controls
  private _analysisLRU = new Map<string, SpacyFullAnalysis>();
  private _helperLRU   = new Map<string, SpacyHelperDoc>();
  private _LRU_MAX = parseInt(env.SPACY_LRU_MAX || '128');

  // precompiled JSON-driven patterns
  private negationPatterns: RegExp[] = [];
  private sarcasmPatterns: Array<{rx:RegExp; conf:number}> = [];
  private edgePatterns: Array<{rx:RegExp; cat:string}> = [];
  private intensityPatterns: Array<{rx:RegExp; mult:number; level?:string}> = [];

  // raw config sets (loaded once)
  private contextClassifiers: any = { contexts: [] };
  private negationIndicators: any = { patterns: [] };
  private sarcasmIndicators: any = { patterns: [] };
  private intensityModifiers: any = { modifiers: [] };
  private phraseEdges: any = { edges: [] };

  // P taxonomy & rule seeds
  private pTaxonomy: { P_MAP: Record<string,string>; RULE_SEEDS: Record<string,string[]> } = { P_MAP: {}, RULE_SEEDS: {} };

  // Precompiled P rule patterns
  private pRulePatterns: Record<string, RegExp[]> = {};

  // Optional zero-shot (lazy)
  private _zshot: any = null;
  private _pEnabled: boolean = String(env.SPACY_P_ENABLE || '1') === '1';
  private _pZeroShot: boolean = String(env.SPACY_P_ZSHOT || '0') === '1'; // opt-in
  private _pThreshold: number = parseFloat(env.SPACY_P_THRESHOLD || '0.45');

  // simple entity + token regexes
  private entityPatterns = {
    PERSON: /\b(?!(?:The|Next|Last|First)\b)([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,2})\b/g, // avoid common title words
    DATE: /\b(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}|\d{1,2}\/\d{1,2}\/\d{2,4}|\d{4}-\d{2}-\d{2}|today|tomorrow|yesterday|next\s+(?:week|month|year)|last\s+(?:week|month|year))\b/gi,
    ORG: /\b(?:[A-Z][a-z]*(?:\s+[A-Z][a-z]*)*\s+(?:Inc|Corp|LLC|Ltd|Company|Co|Organization|Foundation|Institute|University|College|School|Hospital|Bank|Group|Team|Department|Agency|Bureau|Office)\.?)\b/g,
    MONEY: /\b(?:\$\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+\s*(?:dollars?|cents?|bucks?|grand)|(?:hundred|thousand|million|billion)\s*(?:dollars?|bucks?))\b/gi,
    INTENSITY: /\b(very|extremely|really|quite|somewhat|a little|slightly|incredibly|totally|completely|barely|hardly|absolutely|utterly)\b/gi,
    NEGATION: /\b(not|don't|won't|can't|shouldn't|wouldn't|couldn't|haven't|hasn't|hadn't|isn't|aren't|wasn't|weren't|never|no|none|nothing|nobody|nowhere)\b/gi
  } as const;

  private SAFE_MODE: boolean;

  constructor(opts: any = {}) {
    this.dataPath = opts.dataPath || resolve(process.cwd(), 'data');
    this.mode = (opts.mode as Mode) || (env.SPACY_MODE as Mode) || 'balanced';
    
    // Environment variable budget controls
    if (env.SPACY_MAX_MILLIS) this.budgets.maxMillis = parseInt(env.SPACY_MAX_MILLIS);
    if (env.SPACY_MAX_CHARS) this.budgets.maxChars = parseInt(env.SPACY_MAX_CHARS);
    if (env.SPACY_MAX_TOKENS) this.budgets.maxTokens = parseInt(env.SPACY_MAX_TOKENS);
    
    if (opts.budgets) this.budgets = { ...this.budgets, ...opts.budgets };
    this.SAFE_MODE = String(env.SPACY_SAFE_MODE || '').trim() === '1' || !!opts.safeMode;
    this._loadAll();
    this._precompile();
  }

  // ---------- LRU helpers ----------
  private _lruGet<T>(m: Map<string, T>, k: string): T | null {
    const v = m.get(k);
    if (!v) return null;
    m.delete(k); m.set(k, v);
    return v;
    }
  private _lruSet<T>(m: Map<string, T>, k: string, v: T) {
    if (m.has(k)) m.delete(k);
    m.set(k, v);
    if (m.size > this._LRU_MAX) {
      const firstKey = m.keys().next().value as string;
      m.delete(firstKey);
    }
  }

  // ---------- data loading ----------
  private _readJsonSafe(file: string, fb: any = null): any {
    if (this.SAFE_MODE) return fb; // skip disk in safe mode
    const tries = [
      join(process.cwd(), 'data', file),
      join(this.dataPath, file),
      join(resolve(__dirname, '../../../data'), file),
      join(resolve(__dirname, '../../../../data'), file),
      join(resolve('/vercel/path0', 'data'), file),
      join(resolve(env.LAMBDA_TASK_ROOT || process.cwd(), 'data'), file)
    ];
    for (const p of tries) {
      try {
        const content = readFileSync(p, 'utf8');
        logger.info(`[SpacyService] Loaded ${file} from ${p} (${content.length} chars)`);
        return JSON.parse(content);
      } catch (e: any) {
        logger.debug(`[SpacyService] Failed ${file}@${p}: ${e.message}`);
      }
    }
    logger.warn(`[SpacyService] Falling back for ${file}`);
    return fb;
  }

  private _loadAll(): void {
    this.contextClassifiers  = this._readJsonSafe('context_classifier.json', { contexts: [] });
    this.negationIndicators  = this._readJsonSafe('negation_patterns.json', { patterns: [] });
    this.sarcasmIndicators   = this._readJsonSafe('sarcasm_indicators.json', { patterns: [] });
    this.intensityModifiers  = this._readJsonSafe('intensity_modifiers.json', { modifiers: [] });
    this.phraseEdges         = this._readJsonSafe('phrase_edges.json', { edges: [] });

    // NEW: p taxonomy
    this.pTaxonomy           = this._readJsonSafe('p_taxonomy.json', { P_MAP: {}, RULE_SEEDS: {} });
  }

  private _precompile(): void {
    // Negation
    const neg = (this.negationIndicators?.indicators || this.negationIndicators?.negation_indicators || this.negationIndicators?.patterns || []) as any[];
    this.negationPatterns = neg.map((p) => {
      try { return new RegExp(p.pattern || p, 'i'); } catch { return null; }
    }).filter(Boolean) as RegExp[];

    // Sarcasm (merge base + JSON)
    const baseSarcasm = [
      /oh\s+(?:great|wonderful|fantastic|perfect|brilliant)/i,
      /yeah\s+(?:right|sure|ok)/i,
      /(?:sure|fine|whatever)(?:\s*[.!]){2,}/i,
      /\b(?:obviously|clearly|definitely)\b.*\?/i
    ].map(rx => ({ rx, conf: 0.7 }));

    const jsonSarcasm = ((this.sarcasmIndicators?.sarcasm_indicators || this.sarcasmIndicators?.patterns || []) as any[])
      .map((e) => { try { return { rx: new RegExp(e.pattern || e, 'i'), conf: e.impact ? Math.min(1, Math.abs(e.impact)) : 0.6 }; } catch { return null; } })
      .filter(Boolean) as Array<{rx:RegExp; conf:number}>;

    this.sarcasmPatterns = [...baseSarcasm, ...jsonSarcasm];

    // Phrase edges
    this.edgePatterns = ((this.phraseEdges?.edges || []) as any[])
      .map((e) => { try { return { rx: new RegExp(e.pattern, 'i'), cat: e.category || 'edge' }; } catch { return null; } })
      .filter(Boolean) as Array<{rx:RegExp; cat:string}>;

    // Intensity modifiers
    const mods = (this.intensityModifiers?.modifiers || this.intensityModifiers || []) as any;
    if (Array.isArray(mods)) {
      this.intensityPatterns = mods.map((m: any) => {
        try { return { rx: new RegExp(m.pattern || m.regex, 'i'), mult: m.multiplier ?? m.baseMultiplier ?? 1, level: m.class }; }
        catch { return null; }
      }).filter(Boolean) as Array<{rx:RegExp; mult:number; level?:string}>;
    } else if (mods && typeof mods === 'object') {
      this.intensityPatterns = [];
      Object.entries(mods).forEach(([lvl, dict]: [string, any]) => {
        Object.entries(dict || {}).forEach(([k, v]: [string, any]) => {
          try { this.intensityPatterns.push({ rx: new RegExp(k, 'i'), mult: Number(v) || 1, level: lvl }); } catch {}
        });
      });
    }

    // ---- P rule precompile ----
    this.pRulePatterns = {};
    const { RULE_SEEDS } = this.pTaxonomy || { RULE_SEEDS: {} };
    Object.entries(RULE_SEEDS || {}).forEach(([pid, phrases]: [string, any]) => {
      const arr = Array.isArray(phrases) ? phrases : [];
      this.pRulePatterns[pid] = arr
        .map((p) => {
          try {
            // token-ish match: \bphrase\b unless phrase already looks like a regex
            const isRegex = /[\\^$.*+?()[\]{}|]/.test(p);
            return new RegExp(isRegex ? p : `\\b${p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
          } catch { return null; }
        })
        .filter(Boolean) as RegExp[];
    });

    // One-line startup summary
    logger.info('SpaCy client initialized', this.getProcessingSummary());
    logger.info(`[SpaCy] mode=${this.mode} LRU=${this._LRU_MAX} budgets=${JSON.stringify(this.budgets)} P-enabled=${this._pEnabled}`);
  }

  // ---------- tiny NLP helpers ----------
  private simplePOSTag(word: string): string {
    const w = word;
    const lw = w.toLowerCase();
    const pron = new Set(['i','you','he','she','it','we','they','me','him','her','us','them','my','your','our','their','yours',"you're","youre"]);
    const aux  = new Set(['am','is','are','was','were','be','been','being','do','does','did','have','has','had','will','would','could','should','may','might','must']);
    if (pron.has(lw)) return 'PRON';
    if (aux.has(lw)) return 'AUX';
    if (/[a-z]+(ing|ed)$/.test(lw)) return 'VERB';
    if (/[a-z]+ly$/.test(lw)) return 'ADV';
    if (/^[A-Z][a-z]+$/.test(w) && !/^[A-Z]+$/.test(w)) return 'PROPN'; // avoid mid-sentence ALLCAPS
    if (/^[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]+$/.test(w)) return 'PUNCT';
    return /[a-z]/i.test(w) ? 'NOUN' : 'X';
  }

  private basicLemmatize(word: string): string {
    let w = word.toLowerCase()
      .replace(/[\u2018\u2019]/g, "'")  // normalize curly apostrophes
      .replace(/\u00A0/g, ' ');         // normalize NBSP if needed

    if (w.endsWith("n't")) return w.replace(/n't$/, " not"); // expand contractions
    if (/(?:'re|'ve|'ll|'d)$/.test(w)) w = w.replace(/'(re|ve|ll|d)$/, '');
    if (w.endsWith('ing') && w.length > 4) return w.slice(0,-3);
    if (w.endsWith('ed') && w.length > 3)  return w.slice(0,-2);
    if (w.endsWith('s')  && w.length > 3)  return w.slice(0,-1);
    return w;
  }

  private isStopWord(word: string): boolean {
    return DEFAULT_STOPWORDS.has(word.toLowerCase());
  }

  private clamp(text: string): string {
    return text.length > this.budgets.maxChars ? text.slice(0, this.budgets.maxChars) : text;
  }

  private splitTokens(text: string): SpacyToken[] {
    const tokens: SpacyToken[] = [];
    // Use shared Unicode/emoji-aware tokenizer for consistency
    const tokenStrings = tokenize(text);
    let charOffset = 0;
    
    for (let i = 0; i < tokenStrings.length; i++) {
      const t = tokenStrings[i];
      const start = text.indexOf(t, charOffset);
      const end = start + t.length;
      charOffset = end;
      
      tokens.push({
        text: t,
        index: i,
        pos: this.simplePOSTag(t),
        lemma: this.basicLemmatize(t),
        is_alpha: /^[A-Za-z]+$/.test(t),
        is_stop: this.isStopWord(t),
        is_punct: /^[^\w\s]+$/.test(t),
        start, 
        end
      });
    }
    return tokens;
  }

  private splitSents(text: string): Array<{start:number; end:number}> {
    const spans: Array<{start:number; end:number}> = [];
    const rx = /[.!?]+|\n+/g;
    let last = 0; let m: RegExpExecArray | null;
    while ((m = rx.exec(text)) !== null) {
      const end = m.index + m[0].length;
      const slice = text.slice(last, end).trim();
      if (slice) spans.push({ start: last, end });
      last = end;
    }
    if (last < text.length) {
      const slice = text.slice(last).trim();
      if (slice) spans.push({ start: last, end: text.length });
    }
    return spans.length ? spans : [{ start: 0, end: text.length }];
  }

  private extractEntities(text: string): SpacyEntity[] {
    const ents: SpacyEntity[] = [];
    
    // Extract all entity types
    const entityTypes = [
      { pattern: this.entityPatterns.PERSON, label: 'PERSON' },
      { pattern: this.entityPatterns.DATE, label: 'DATE' },
      { pattern: this.entityPatterns.ORG, label: 'ORG' },
      { pattern: this.entityPatterns.MONEY, label: 'MONEY' }
    ];
    
    for (const { pattern, label } of entityTypes) {
      // Reset regex lastIndex to ensure fresh start
      pattern.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = pattern.exec(text)) !== null) {
        ents.push({ 
          text: m[0], 
          label, 
          start: m.index, 
          end: m.index + m[0].length 
        });
      }
    }
    
    // Sort by start position for consistent ordering
    return ents.sort((a, b) => a.start - b.start);
  }

  private classifyNegationType(w: string): string {
    const contr = ["don't","won't","can't","shouldn't","wouldn't","couldn't","haven't","hasn't","hadn't","isn't","aren't","wasn't","weren't"];
    if (contr.includes(w)) return 'contraction';
    if (['not','no'].includes(w)) return 'simple';
    if (['never','nothing','nobody','nowhere'].includes(w)) return 'absolute';
    return 'other';
  }

  private findNegationDeps(text: string, toks: SpacyToken[], sents: Array<{start:number;end:number}>) {
    const deps: Array<{ rel: string; head: number; token: number; start: number; end: number }> = [];
    const subtreeSpan: Record<number, { start: number; end: number }> = {};

    const negWordSet = new Set([
      'not',"don't","dont","won't","wont","can't","cant","shouldn't","shouldnt","wouldn't","wouldnt",
      "couldn't","couldnt","haven't","havent","hasn't","hasnt","hadn't","hadnt","isn't","isnt","aren't","arent",
      "wasn't","wasnt","weren't","werent",'never','no','nothing','nobody','nowhere'
    ]);

    // Build sentence map by char
    const findSentByChar = (ch: number) => sents.find(s => ch >= s.start && ch < s.end) || { start: 0, end: text.length };

    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      const norm = t.text.toLowerCase();
      if (!negWordSet.has(norm)) continue;

      // Prefer right-ward head within window; else left; prefer VERB>AUX>ADJ
      const pref = (idx: number) => (toks[idx].pos === 'VERB' ? 3 : toks[idx].pos === 'AUX' ? 2 : toks[idx].pos === 'ADJ' ? 1 : 0);
      let head = -1, best = -1;
      for (let j = i+1; j <= Math.min(i+6, toks.length-1); j++) { const p = pref(j); if (p > best) { best = p; head = j; if (p===3) break; } }
      if (head === -1) for (let j = i-1; j >= Math.max(0, i-6); j--) { const p = pref(j); if (p > best) { best = p; head = j; if (p===3) break; } }
      if (head === -1) head = i;

      // Scope: tighten around head token with a small window when possible
      const sent = findSentByChar(toks[head].start ?? 0);
      const tokenStart = toks[head].start ?? sent.start;
      const tokenEnd   = toks[head].end   ?? sent.end;
      const pad = 40; // chars around head
      const localStart = Math.max(sent.start, tokenStart - pad);
      const localEnd   = Math.min(sent.end,   tokenEnd + pad);
      deps.push({ rel: 'neg', head, token: i, start: localStart, end: localEnd });
      if (!subtreeSpan[head]) subtreeSpan[head] = { start: localStart, end: localEnd };
    }
    return { deps, subtreeSpan };
  }

  private detectNegation(text: string): NegationAnalysis {
    const negations: any[] = [];
    const lower = text.toLowerCase();
    
    // Multi-token negation patterns (higher precedence)
    const multiTokenPatterns = [
      /\bnot\s+really\b/gi,
      /\bno\s+longer\b/gi,
      /\bnot\s+at\s+all\b/gi,
      /\bnot\s+quite\b/gi,
      /\bhardly\s+ever\b/gi,
      /\bnever\s+again\b/gi,
      /\bno\s+way\b/gi,
      /\bnot\s+anymore\b/gi,
      /\bfar\s+from\b/gi
    ];
    
    for (const pattern of multiTokenPatterns) {
      pattern.lastIndex = 0; // Reset regex
      let m: RegExpExecArray | null;
      while ((m = pattern.exec(text)) !== null) {
        const pos = m.index;
        const scope = this.scopeToClause(text, pos);
        negations.push({ 
          negationWord: m[0], 
          position: pos, 
          scope, 
          type: 'multi_token' 
        });
      }
    }
    
    // Single token patterns (lower precedence)
    const rx = this.entityPatterns.NEGATION;
    rx.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = rx.exec(lower)) !== null) {
      const word = m[0];
      const pos = m.index;
      
      // Skip if already covered by multi-token pattern
      const alreadyCovered = negations.some(neg => 
        pos >= neg.position && pos < neg.position + neg.negationWord.length
      );
      
      if (!alreadyCovered) {
        const scope = this.scopeToClause(text, pos);
        negations.push({ 
          negationWord: word, 
          position: pos, 
          scope, 
          type: this.classifyNegationType(word) 
        });
      }
    }
    
    // JSON patterns
    for (const r of this.negationPatterns) {
      try { 
        if (r.test(text)) {
          negations.push({ 
            negationWord: r.source, 
            position: -1, 
            scope: 'json', 
            type: 'complex_pattern' 
          }); 
        } 
      } catch {}
    }
    
    return { hasNegation: negations.length > 0, negations, negationCount: negations.length };
  }

  // Enhanced scope function that stops at clause boundaries
  private scopeToClause(text: string, pos: number): string {
    const before = text.slice(0, pos);
    const after = text.slice(pos);
    
    // Find clause boundaries (comma, semicolon, dash, or sentence end)
    const clauseStart = Math.max(
      before.lastIndexOf(','),
      before.lastIndexOf(';'),
      before.lastIndexOf(' - '),
      before.lastIndexOf('.'),
      before.lastIndexOf('!'),
      before.lastIndexOf('?'),
      0
    );
    
    const clauseEndMatch = after.match(/[,.;!\?]|\s-\s/);
    const clauseEnd = clauseEndMatch ? pos + clauseEndMatch.index! : text.length;
    
    return text.slice(clauseStart, clauseEnd).trim();
  }

  private detectSarcasm(text: string): SarcasmAnalysis {
    const hits: any[] = [];
    for (const { rx, conf } of this.sarcasmPatterns) {
      let rxGlobal = rx;
      if (!rx.global) { // clone with /g if missing
        const flags = (rx.ignoreCase ? 'i' : '') + (rx.multiline ? 'm' : '') + 'g';
        rxGlobal = new RegExp(rx.source, flags);
      }
      let m: RegExpExecArray | null;
      while ((m = rxGlobal.exec(text)) !== null) hits.push({ pattern: m[0], position: m.index, type: 'linguistic_pattern', confidence: conf });
    }
    // punctuation cues (global)
    const punct = /[!]{2,}|[?]{2,}|[.]{3,}/g; let mm: RegExpExecArray | null;
    while ((mm = punct.exec(text)) !== null) hits.push({ pattern: mm[0], position: mm.index, type: 'punctuation_pattern', confidence: 0.4 });

    // bounded aggregation
    const sum = hits.reduce((s,h)=>s+(h.confidence||0.4),0);
    const score = Math.min(1, sum / Math.max(1, hits.length));
    const prob  = Math.min(1, 0.25*hits.length + 0.5*score); // tunable
    return { hasSarcasm: hits.length>0, sarcasmIndicators: hits, sarcasmScore: score, overallSarcasmProbability: prob };
  }

  private detectIntensity(text: string): IntensityAnalysis {
    const words: any[] = [];
    const rx = this.entityPatterns.INTENSITY;
    let m: RegExpExecArray | null;
    while ((m = rx.exec(text)) !== null) {
      const w = m[0].toLowerCase();
      let level = 'moderate', mult = 1.0;
      if (['extremely','incredibly','totally','completely','absolutely','utterly'].includes(w)) { level='high'; mult=1.5; }
      else if (['very','really','quite'].includes(w)) { level='moderate-high'; mult=1.2; }
      else if (['somewhat','a little','slightly','barely','hardly'].includes(w)) { level='low'; mult=0.7; }
      words.push({ word: w, position: m.index, level, multiplier: mult, scope: this.peekNext(text, m.index) });
    }
    for (const pat of this.intensityPatterns) {
      let mm: RegExpExecArray | null;
      const g = pat.rx.global ? pat.rx : new RegExp(pat.rx.source, (pat.rx.ignoreCase?'i':'')+'g');
      while ((mm = g.exec(text)) !== null) words.push({ word: pat.rx.source, position: mm.index, level: pat.level || 'custom', multiplier: pat.mult, scope: 'json' });
    }
    // bounded blend (prevents explosion)
    const bump = words.reduce((prod, w)=> prod * (1 - Math.min(Math.max((w.multiplier||1)-1,0), 0.35)), 1);
    const overall = 1 - bump; // in [0,1)
    const dom = (() => { const m: Record<string,number> = {}; words.forEach((w:any)=>m[w.level]=(m[w.level]||0)+1); return Object.entries(m).sort((a,b)=>b[1]-a[1])[0]?.[0] || 'neutral';})();
    return { hasIntensity: words.length>0, intensityWords: words, intensityCount: words.length, overallIntensity: overall, dominantLevel: dom };
  }

  private detectEdges(text: string): string[] {
    const hits: string[] = [];
    for (const { rx, cat } of this.edgePatterns) { try { if (rx.test(text)) hits.push(cat); } catch {} }
    return hits;
  }

  private classifyContext(text: string, attachmentStyle?: string): ContextClassification {
    const start = now();
    const toks = this.splitTokens(text);
    const lower = text.toLowerCase();
    const sents = this.splitSents(text);
    const confs = this.contextClassifiers?.contexts || [];
    const engine = this.contextClassifiers?.engine || {};
    
    // Environment variable controls
    const maxContexts = parseInt(env.SPACY_MAX_CONTEXTS || '8');
    const scoreThreshold = parseFloat(env.SPACY_CONTEXT_THRESHOLD || '0.05');
    const usePositionBoosts = env.SPACY_POSITION_BOOSTS !== '0';
    const useCooldowns = env.SPACY_COOLDOWNS !== '0';
    
    const contextual: any[] = [];
    const contextLastSeen = new Map<string, number>(); // sentence-based cooldowns
    const bucketScores = { clear: 0, caution: 0, alert: 0 };
    const bucketEvidence = { clear: new Set(), caution: new Set(), alert: new Set() };

    // Preprocess: generic tokens and negation/sarcasm windows
    const genericTokens = new Set([
      ...(engine.genericTokens?.globalStop || []),
      ...(engine.genericTokens?.pronouns || [])
    ]);
    const isGenericPolicy = engine.genericTokens?.policy?.ignoreForBuckets || {};
    
    // Calculate global format cues
    const globalAllCapsRatio = (text.match(/[A-Z]/g) || []).length / Math.max(1, (text.match(/[A-Za-z]/g) || []).length);
    const globalExclamationCount = (text.match(/!/g) || []).length;
    
    // Per-sentence analysis with sophisticated scoring
    for (let sentIdx = 0; sentIdx < sents.length; sentIdx++) {
      const sent = sents[sentIdx];
      const sentText = text.slice(sent.start, sent.end);
      const sentLower = sentText.toLowerCase();
      
      // Format cues (all caps, exclamations)
      const allCapsRatio = (sentText.match(/[A-Z]/g) || []).length / Math.max(1, (sentText.match(/[A-Za-z]/g) || []).length);
      const exclamationCount = (sentText.match(/!/g) || []).length;
      
      for (const ctx of confs) {
        const ctxId = ctx.id || ctx.context;
        const priority = ctx.priority || 1;
        const windowTokens = ctx.windowTokens || engine.windowing?.defaultWindowTokens || 24;
        
        // Cooldown check
        const lastSeen = contextLastSeen.get(ctxId) || -1;
        const cooldownSent = Math.floor((ctx.cooldown_ms || 0) / (engine.conflictResolution?.cooldownSentenceMs || 300));
        if (useCooldowns && lastSeen >= 0 && (sentIdx - lastSeen) < cooldownSent) {
          continue; // Skip due to cooldown
        }
        
        let score = 0;
        const matched: string[] = [];
        
        // Basic tone cues (simple tokens)
        const basicCues = ctx.toneCues || [];
        for (const cue of basicCues) {
          if (sentLower.includes(cue.toLowerCase())) {
            const cueWeight = ctx.weight || 1.0;
            score += cueWeight * 0.1;
            matched.push(cue);
          }
        }
        
        // Weighted patterns (regex, ngrams, tokens)
        const weightedCues = ctx.toneCuesWeighted || [];
        for (const wcue of weightedCues) {
          const pattern = wcue.pattern;
          const weight = wcue.weight || 0.1;
          const type = wcue.type || 'token';
          
          try {
            let regex: RegExp;
            if (type === 'regex') {
              regex = new RegExp(pattern, 'gi');
            } else if (type === 'ngram') {
              regex = new RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
            } else { // token
              regex = new RegExp('\\b' + pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'gi');
            }
            
            let m: RegExpExecArray | null;
            while ((m = regex.exec(sentText)) !== null) {
              // Check if token is generic and should be ignored for certain buckets
              const matchedToken = m[0].toLowerCase();
              const isGeneric = genericTokens.has(matchedToken);
              
              // Apply generic token policy
              if (isGeneric) {
                const maxGenericPoints = engine.genericTokens?.policy?.maxPointsPerGenericToken || 0;
                score += Math.min(weight, maxGenericPoints);
              } else {
                score += weight;
              }
              matched.push(pattern);
              
              // Track evidence for bucket guards
              if (ctx.confidenceBoosts) {
                Object.entries(ctx.confidenceBoosts).forEach(([bucket, boost]: [string, any]) => {
                  if (boost > 0 && !isGeneric) {
                    (bucketEvidence as any)[bucket]?.add(matchedToken);
                  }
                });
              }
            }
          } catch (e) {
            // Skip malformed regex
            logger.warn(`[SpaCy] Invalid pattern: ${pattern}`);
          }
        }
        
        // Counter cues (dampening)
        const counterCues = ctx.counterCues || [];
        for (const counter of counterCues) {
          if (sentLower.includes(counter.toLowerCase())) {
            score *= 0.7; // Dampen by 30%
          }
        }
        
        // Position boosts
        if (usePositionBoosts && ctx.positionBoost && score > 0) {
          if (sentIdx === 0 && ctx.positionBoost.start) {
            score += ctx.positionBoost.start;
          }
          if (sentIdx === sents.length - 1 && ctx.positionBoost.end) {
            score += ctx.positionBoost.end;
          }
          if (allCapsRatio > 0.5 && ctx.positionBoost.allCaps) {
            score += ctx.positionBoost.allCaps;
          }
        }
        
        // Format cue effects
        if (allCapsRatio > 0.3) {
          score += (engine.formatCues?.allCaps?.alert || 0);
        }
        if (exclamationCount > 0) {
          score += (engine.formatCues?.exclamationsPerSentence?.alert || 0) * exclamationCount;
        }
        
        // Attachment style adjustments
        if (attachmentStyle && ctx.attachmentAdjustments && ctx.attachmentAdjustments[attachmentStyle]) {
          const adjustments = ctx.attachmentAdjustments[attachmentStyle];
          // Apply adjustments to bucket scores later, track context score
          Object.entries(adjustments).forEach(([bucket, adj]: [string, any]) => {
            (bucketScores as any)[bucket] += adj * score;
          });
        }
        
        // Repeat decay
        const repeatDecay = ctx.repeatDecay || engine.conflictResolution?.repeatDecayDefault || 0.75;
        if (contextLastSeen.has(ctxId)) {
          score *= repeatDecay;
        }
        
        // Apply max boosts limit
        const maxBoosts = ctx.maxBoostsPerMessage || 999;
        if (matched.length > maxBoosts) {
          score *= (maxBoosts / matched.length);
        }
        
        // Record context if above threshold
        if (score > scoreThreshold) {
          contextual.push({
            context: ctx.context || ctxId,
            score,
            confidence: 0, // Will be calculated later with softmax
            matchedPatterns: matched,
            priority,
            sentenceIndex: sentIdx,
            description: ctx.description
          });
          
          contextLastSeen.set(ctxId, sentIdx);
        }
      }
    }
    
    // Apply negation and sarcasm effects
    const hasNegation = this.detectNegation(text).hasNegation;
    const hasSarcasm = this.detectSarcasm(text).hasSarcasm;
    
    if (hasNegation && engine.negation?.effect) {
      Object.entries(engine.negation.effect).forEach(([bucket, effect]: [string, any]) => {
        (bucketScores as any)[bucket] += effect;
      });
    }
    
    if (hasSarcasm && engine.sarcasm?.effect) {
      Object.entries(engine.sarcasm.effect).forEach(([bucket, effect]: [string, any]) => {
        (bucketScores as any)[bucket] += effect;
      });
    }
    
    // Apply bucket guards
    const guards = engine.bucketGuards || {};
    const minEvidence = guards.minEvidenceTokensByBucket || {};
    
    // Clear bucket guard logic
    if (guards.clear) {
      const clearGuard = guards.clear;
      const evidenceCount = bucketEvidence.clear.size;
      
      if (evidenceCount < (minEvidence.clear || 1)) {
        bucketScores.clear *= 0.1; // Severely dampen if insufficient evidence
      }
      
      if (clearGuard.requireDeescalatoryContext) {
        const hasDeescalatory = contextual.some(c => 
          clearGuard.eligibleContexts?.includes(c.context) || 
          confs.find((ctx: any) => ctx.context === c.context)?.polarity === 'deescalatory'
        );
        if (!hasDeescalatory) {
          bucketScores.clear *= 0.3;
        }
      }
      
      if (clearGuard.cancelIfLocalNegation && hasNegation) {
        bucketScores.clear *= 0.2;
      }
      
      if (clearGuard.dampenIfEscalatoryContextsActive) {
        const hasEscalatory = contextual.some(c => 
          confs.find((ctx: any) => ctx.context === c.context)?.polarity === 'escalatory'
        );
        if (hasEscalatory) {
          bucketScores.clear *= clearGuard.dampenIfEscalatoryContextsActive;
        }
      }
      
      // Overshadow logic
      if (clearGuard.overshadowedBy && bucketScores.alert >= clearGuard.overshadowedBy.atOrAbove) {
        const ratio = bucketScores.clear / Math.max(bucketScores.alert, 0.01);
        if (ratio < clearGuard.overshadowedBy.ratioRequiredForClear) {
          bucketScores.clear *= 0.5;
        }
      }
    }
    
    // Alert and caution multipliers
    if (guards.alert) {
      if (globalAllCapsRatio > 0.3) {
        bucketScores.alert *= (guards.alert.allCapsMultiplier || 1.0);
      }
      if (globalExclamationCount > 0) {
        bucketScores.alert *= Math.pow(guards.alert.exclamationMultiplier || 1.0, globalExclamationCount);
      }
    }
    
    // Sort by priority, then score
    contextual.sort((a, b) => {
      if (a.priority !== b.priority) return b.priority - a.priority;
      return b.score - a.score;
    });
    
    // Limit to max contexts and apply conflict resolution
    const maxContextsPerSent = engine.conflictResolution?.maxContextsPerSentence || 3;
    const filteredContexts = contextual.slice(0, Math.min(maxContexts, maxContextsPerSent));
    
    // Calculate softmax confidence scores
    if (filteredContexts.length > 0) {
      const logits = filteredContexts.map(c => c.score);
      const maxLogit = Math.max(...logits);
      const exps = logits.map(logit => Math.exp(logit - maxLogit));
      const sumExps = exps.reduce((sum, exp) => sum + exp, 0);
      
      filteredContexts.forEach((ctx, i) => {
        ctx.confidence = exps[i] / sumExps;
      });
    }
    
    const processingTime = now() - start;
    if (processingTime > 5) {
      logger.warn(`[SpaCy] Context classification took ${processingTime.toFixed(2)}ms for ${text.length} chars`);
    }
    
    return {
      primaryContext: filteredContexts[0]?.context || 'general',
      secondaryContext: filteredContexts[1]?.context || null,
      allContexts: filteredContexts.map(c => ({
        context: c.context,
        score: c.score,
        confidence: c.confidence || 0,
        matchedPatterns: c.matchedPatterns || [],
        description: c.description
      })),
      confidence: filteredContexts[0]?.confidence || 0.1
    };
  }

  // ---------- tiny utils ----------
  private scopeWindow(text: string, pos: number): string {
    const after = text.slice(pos);
    const m = after.match(/^.{0,160}?(?=[\.!\?\n]|$)/);
    return (m?.[0] || after.slice(0,160)).trim();
  }
  private peekNext(text: string, pos: number): string {
    const rest = text.substring(pos).trimStart();
    const m = rest.match(/^\S+\s+(\S+)/);
    return m?.[1] || '';
  }

  // ---- P: rule-only scorer ----
  private _pRuleScore(text: string): PScoreMap {
    const scores: PScoreMap = {};
    for (const pid of Object.keys(this.pRulePatterns)) {
      let s = 0;
      for (const rx of this.pRulePatterns[pid]) {
        rx.lastIndex = 0;
        if (rx.test(text)) s += 0.25; // tweak via env later if needed
      }
      if (s > 0) scores[pid] = s;
    }
    return scores;
  }

  // ---- P: ONNX-powered zero-shot scorer (lazy import; cloud optimized) ----
  private async _ensureZeroShot(): Promise<void> {
    if (this._zshot || !this._pZeroShot) return;
    try {
      // Use ONNX-based inference instead of transformers.js
      const { onnxInference } = await import('./onnxInference');
      const healthCheck = await onnxInference.healthCheck();
      
      if (healthCheck.status === 'healthy') {
        this._zshot = onnxInference; // Use ONNX service directly
        logger.info('[SpacyService] ONNX zero-shot classification enabled');
      } else {
        logger.warn('[SpacyService] ONNX service not ready, P-code zero-shot disabled');
        this._pZeroShot = false;
      }
    } catch (error) {
      logger.warn('[SpacyService] Failed to load ONNX inference, P-code zero-shot disabled:', error instanceof Error ? error.message : String(error));
      this._pZeroShot = false;
    }
  }

  private async _pZeroShotScore(text: string): Promise<PScoreMap> {
    await this._ensureZeroShot();
    if (!this._zshot) return {};
    
    const P_MAP = this.pTaxonomy?.P_MAP || {};
    const labels = Object.values(P_MAP).map((v: string) => v.replace(/_/g, ' '));
    
    try {
      // Use ONNX-based zero-shot classification
      const res = await this._zshot.runZeroShot(text, labels);
      const ml: PScoreMap = {};
      
      // Map verbalization -> P id
      const labelToPid = new Map<string, string>();
      Object.entries(P_MAP).forEach(([pid, name]) => 
        labelToPid.set(name.replace(/_/g, ' '), pid)
      );
      
      // Convert ONNX results to expected format
      for (const prediction of res.predictions) {
        const pid = labelToPid.get(prediction.label);
        if (pid) {
          ml[pid] = prediction.confidence;
        }
      }
      
      return ml;
      
    } catch (error) {
      logger.warn('[SpacyService] ONNX zero-shot scoring failed:', error);
      return {};
    }
  }

  // ---- P: merge + threshold ----
  private _mergePScores(a: PScoreMap, b: PScoreMap): PScoreMap {
    const out: PScoreMap = {};
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    keys.forEach(k => out[k] = (a[k] || 0) + (b[k] || 0));
    return out;
  }

  // Public P classifier
  async classifyP(text: string, threshold = this._pThreshold): Promise<PClassification> {
    if (!this._pEnabled) return { p_scores: {}, ruleScores: {}, mlScores: {}, topP: [] };

    const ruleScores = this._pRuleScore(text);
    const mlScores   = this._pZeroShot ? await this._pZeroShotScore(text) : {};
    const merged     = this._mergePScores(ruleScores, mlScores);

    // keep ≥ threshold
    const p_scores: PScoreMap = {};
    Object.entries(merged).forEach(([k, v]) => { if (v >= threshold) p_scores[k] = v; });

    const topP = Object.keys(p_scores).sort((a, b) => p_scores[b] - p_scores[a]);
    return { p_scores, ruleScores, mlScores, topP };
  }

  // -----------------------------
  // Public API
  // -----------------------------

  /**
   * Main entry used by toneAnalysis.ts (spacyLiteSync).
   * Returns compact result + extra fields (tokens/sents/deps/subtreeSpan).
   */
  process(text: string, opts: any = {}): SpacyProcessResult {
    const start = now();
    const original = this.clamp((text || '').replace(/\r\n?/g, '\n')); // normalize whitespace for stable char offsets
    const attachmentStyle = opts.attachmentStyle || opts.attachment_style; // Support both formats

    // LRU (by version + mode + text + attachment)
    const key = `${CLIENT_VERSION}:${this.mode}:${attachmentStyle || 'none'}:${original}`;
    const cached = this._lruGet(this._analysisLRU, key);
    if (cached && cached.processingTimeMs < this.budgets.maxMillis) {
      return this._toProcessResult(cached);
    }

    // Tokenize first (cheap)
    const tokens = this.splitTokens(original);
    const tooMany = tokens.length > this.budgets.maxTokens;

    // Minimal always-on
    const sents = this.splitSents(original);
    const entities = this.extractEntities(original);
    const contextClassification = this.classifyContext(original, attachmentStyle);

    // Negation deps + spans
    const { deps, subtreeSpan } = this.findNegationDeps(original, tokens, sents);

    // Medium/Heavy (gated by performance budgets)
    const negationAnalysis = this.detectNegation(original);
    const sarcasmAnalysis = (!tooMany ? this.detectSarcasm(original) : { 
      hasSarcasm:false, sarcasmIndicators:[], sarcasmScore:0, overallSarcasmProbability:0 
    });
    const intensityAnalysis = (!tooMany ? this.detectIntensity(original) : { 
      hasIntensity:false, intensityWords:[], intensityCount:0, overallIntensity:1, dominantLevel:'neutral' 
    });
    const edgeHits = this.detectEdges(original);

    const processingTime = now() - start;

    const full: SpacyFullAnalysis = {
      originalText: original,
      tokens,
      entities,
      dependencies: deps.map(d => ({ text: original.slice(d.start, d.end), relation: d.rel, start: d.start, end: d.end, head: d.head, token: d.token })),
      contextClassification,
      negationAnalysis,
      sarcasmAnalysis,
      intensityAnalysis,
      _phraseEdgeHits: edgeHits,
      processingTimeMs: processingTime,
      timestamp: new Date().toISOString(),
      sents,
      deps,
      subtreeSpan
    };

    // Attach P classification (non-blocking, best-effort)
    if (this._pEnabled) {
      try {
        // run rule-only synchronously (cheap)
        const ruleOnly = this._pRuleScore(original);
        (full as any)._p_rule = ruleOnly;
        // kick off zero-shot if enabled; don't await in hot path
        if (this._pZeroShot) this._pZeroShotScore(original).then((ml) => {
          (full as any)._p_ml = ml;
        }).catch(()=>{});
      } catch {}
    }

    this._lruSet(this._analysisLRU, key, full);
    return this._toProcessResult(full);
  }

  private _toProcessResult(diag: SpacyFullAnalysis): SpacyProcessResult {
    const contextTop = diag.contextClassification.allContexts[0];
    const context = { label: diag.contextClassification.primaryContext, score: contextTop?.confidence || 0.1 };

    const negScore = Math.min(1, 0.3 + 0.1 * (diag.negationAnalysis.negationCount || 0));
    const sarcScore = diag.sarcasmAnalysis.sarcasmScore || 0;
    const intensityScore = (() => {
      const capsRatio = (() => {
        const caps = (diag.originalText.match(/[A-Z]/g) || []).length;
        const letters = (diag.originalText.match(/[A-Za-z]/g) || []).length || 1;
        return caps / letters;
      })();
      return Math.max(0, Math.min(1,
        (diag.intensityAnalysis.intensityCount || 0) * 0.08 +
        Math.min(capsRatio, 0.35) * 0.6   // lower weight + cap to prevent ALL-CAPS domination
      ));
    })();

    // Extract second-person spans for PRON_2P entities
    const secondPerson = extractSecondPersonTokenSpans(diag.tokens);

    // Combine P scores (rule + ML if available)
    const pRule: PScoreMap = (diag as any)._p_rule || {};
    const pML:   PScoreMap = (diag as any)._p_ml   || {};
    const pMerged = Object.fromEntries(
      Array.from(new Set([...Object.keys(pRule), ...Object.keys(pML)])).map(k => [k, (pRule[k]||0)+(pML[k]||0)])
    ) as PScoreMap;
    const pScores: PScoreMap = {};
    const pThresh = this._pThreshold;
    Object.entries(pMerged).forEach(([k,v]) => { if (v >= pThresh) pScores[k]=v; });
    const pTop = Object.keys(pScores).sort((a,b)=>pScores[b]-pScores[a]);

    return {
      context,
      entities: [
        ...diag.entities,
        ...secondPerson.map(s => ({ 
          text: 'you', 
          label: 'PRON_2P', 
          start: diag.tokens[s.start]?.start ?? 0, 
          end: diag.tokens[s.end]?.end ?? 0 
        }))
      ],
      negation: { present: diag.negationAnalysis.hasNegation, score: diag.negationAnalysis.hasNegation ? negScore : 0 },
      sarcasm: { present: diag.sarcasmAnalysis.hasSarcasm, score: sarcScore },
      intensity: { score: intensityScore },
      phraseEdges: { hits: diag._phraseEdgeHits },
      features: { featureCount: diag.tokens.length },

      // extras expected by spacyLiteSync
      tokens: diag.tokens,
      sents: diag.sents,
      deps: diag.deps,
      subtreeSpan: diag.subtreeSpan,

      // NEW: P-code classification results
      pScores,
      pTop
    };
  }

  /** Rich analysis (sync wrapper) */
  processTextSync(text: string, options: any = {}): SpacyFullAnalysis {
    const r = this.process(text, options) as any;
    return {
      originalText: text,
      tokens: r.tokens || [],
      entities: r.entities || [],
      dependencies: (r.deps || []).map((d: any) => ({ text: text.slice(d.start, d.end), relation: d.rel, start: d.start, end: d.end, head: d.head, token: d.token })),
      contextClassification: {
        primaryContext: r.context?.label || 'general',
        secondaryContext: null,
        allContexts: [{ context: r.context?.label || 'general', score: r.context?.score || 0.1, confidence: r.context?.score || 0.1, matchedPatterns: [] }],
        confidence: r.context?.score || 0.1,
      },
      negationAnalysis: { hasNegation: r.negation?.present || false, negations: [], negationCount: r.negation?.present ? 1 : 0 },
      sarcasmAnalysis: { hasSarcasm: r.sarcasm?.present || false, sarcasmIndicators: [], sarcasmScore: r.sarcasm?.score || 0, overallSarcasmProbability: r.sarcasm?.score || 0 },
      intensityAnalysis: { hasIntensity: (r.intensity?.score || 0) > 0, intensityWords: [], intensityCount: 0, overallIntensity: r.intensity?.score || 1, dominantLevel: 'neutral' },
      _phraseEdgeHits: r.phraseEdges?.hits || [],
      processingTimeMs: 0,
      timestamp: new Date().toISOString(),
      sents: r.sents || [],
      deps: r.deps || [],
      subtreeSpan: r.subtreeSpan || {}
    };
  }

  async processText(text: string, options: any = {}): Promise<SpacyFullAnalysis> {
    return this.processTextSync(text, options);
  }

  async analyze(text: string, patterns?: any[]): Promise<SpacyFullAnalysis> {
    return this.processText(text, { patterns });
  }

  // Minimal helper doc (local; mirrors serverless bridge shape but without network)
  helperDoc(text: string, fields: SpacyHelperField[] = ['tokens','sents','neg_scopes','pos_counts']): SpacyHelperDoc {
    const original = this.clamp(text || '');
    const key = fields.slice().sort().join(',') + '::' + original;
    const cached = this._lruGet(this._helperLRU, key);
    if (cached) return cached;

    const out: SpacyHelperDoc = {};
    const tokens = this.splitTokens(original);
    const sents = this.splitSents(original);

    if (fields.includes('tokens')) {
      out.tokens = tokens.map(t => ({ text: t.text, lemma: t.lemma, pos: t.pos, i: t.index }));
    }
    if (fields.includes('sents')) {
      out.sents = sents;
    }
    if (fields.includes('neg_scopes')) {
      const { deps } = this.findNegationDeps(original, tokens, sents);
      out.neg_scopes = deps.filter(d => d.rel==='neg').map(d => ({ start: d.start, end: d.end, trigger: tokens[d.token]?.text || 'not' }));
    }
    if (fields.includes('pos_counts')) {
      const pc: Record<string, number> = { NOUN:0, VERB:0, ADJ:0, ADV:0, PRON:0 };
      tokens.forEach(t => { if (pc[t.pos] !== undefined) pc[t.pos]++; });
      out.pos_counts = pc;
    }
    if (fields.includes('entities')) {
      out.entities = this.extractEntities(original);
    }

    this._lruSet(this._helperLRU, key, out);
    return out;
  }

  // Status & health
  getProcessingSummary(): any {
    return {
      contexts: this.contextClassifiers?.contexts?.length || 0,
      negation_patterns: this.negationPatterns.length,
      sarcasm_patterns: this.sarcasmPatterns.length,
      intensity_modifiers: this.intensityPatterns.length,
      edges: this.edgePatterns.length,
      lru_cache_size: this._analysisLRU.size,
      helper_cache_size: this._helperLRU.size,
      cache_max_size: this._LRU_MAX,
      budgets: this.budgets
    };
  }

  getServiceStatus(): any {
    return {
      status: 'operational',
      version: CLIENT_VERSION,
      mode: this.mode,
      dataFilesLoaded: {
        context_classifiers: !!this.contextClassifiers,
        negation_indicators: !!this.negationIndicators,
        sarcasm_indicators: !!this.sarcasmIndicators,
        intensity_modifiers: !!this.intensityModifiers,
        phrase_edges: !!this.phraseEdges
      },
      engine_features: {
        weighted_patterns: true,
        priority_system: true,
        cooldown_mechanics: true,
        position_boosts: true,
        attachment_adjustments: true,
        bucket_guards: true,
        sentence_segmentation: true,
        environment_controls: true
      },
      summary: this.getProcessingSummary()
    };
  }

  async healthCheck(): Promise<boolean> { 
    logger.info('SpaCy (local helper) health: OK', this.getProcessingSummary()); 
    return true; 
  }

  // Warmup endpoint for cold start optimization
  async warmup(): Promise<void> {
    const warmupTexts = [
      'I love you so much!',
      'This is really frustrating me',
      'Can we talk about this later?',
      'Thank you for understanding',
      'I need some space right now'
    ];
    
    const attachmentStyles = ['secure', 'anxious', 'avoidant', 'disorganized'];
    
    logger.info('[SpaCy] Starting warmup process...');
    const start = now();
    
    for (const text of warmupTexts) {
      for (const style of attachmentStyles) {
        try {
          this.process(text, { attachmentStyle: style });
        } catch (e) {
          logger.warn(`[SpaCy] Warmup failed for text: ${text}, style: ${style}`, e);
        }
      }
    }
    
    const duration = now() - start;
    logger.info(`[SpaCy] Warmup completed in ${duration.toFixed(2)}ms, cache size: ${this._analysisLRU.size}`);
  }

  // Simple numeric vector for downstream heuristics (kept from prior version)
  async embed(text: string): Promise<number[]> {
    try {
      const analysis = this.process(text);
      const tokens = analysis.tokens || [];
      const features: number[] = [];
      features.push(tokens.length / 100);
      features.push((tokens.filter(t=>t.is_alpha).length) / Math.max(1, tokens.length));
      features.push((tokens.filter(t=>t.is_stop).length) / Math.max(1, tokens.length));
      features.push((tokens.filter(t=>t.pos==='NOUN').length) / Math.max(1, tokens.length));
      features.push((tokens.filter(t=>t.pos==='VERB').length) / Math.max(1, tokens.length));
      features.push((tokens.filter(t=>t.pos==='ADJ').length) / Math.max(1, tokens.length));
      features.push((analysis.entities?.length || 0) / Math.max(1, tokens.length));
      const negCount = (analysis.deps || []).filter(d=>d.rel==='neg').length;
      features.push(negCount / Math.max(1, tokens.length));
      features.push(analysis.sarcasm?.score || 0);
      features.push(analysis.intensity?.score || 1);
      const contextTypes = ['general','conflict','planning','repair','emotional','professional','personal','urgent','casual','formal'];
      const ctxLabel = analysis.context?.label || 'general';
      contextTypes.forEach(type => features.push(type === ctxLabel ? 1 : 0));
      const lower = (text || '').toLowerCase();
      const emoGroups: Record<string,string[]> = {
        joy:['happy','joy','excited','pleased','delighted'],
        anger:['angry','mad','furious','annoyed','frustrated'],
        sadness:['sad','hurt','disappointed','upset','down'],
        fear:['scared','afraid','worried','anxious','nervous'],
        trust:['trust','confident','secure','safe','reliable'],
        surprise:['surprised','shocked','amazed','astonished'],
        disgust:['disgusted','revolted','repulsed','sickened'],
        anticipation:['excited','eager','hopeful','expecting'],
        neutral:['okay','fine','normal','regular'],
        mixed:['conflicted','confused','uncertain','ambivalent']
      };
      Object.values(emoGroups).forEach(words => {
        const c = words.reduce((s,w)=>s+(lower.includes(w)?1:0),0);
        features.push(c / Math.max(1, words.length));
      });
      while (features.length < 30) features.push(0);
      return features.slice(0,30);
    } catch (e) {
      logger.error('Embedding generation failed', e);
      return new Array(30).fill(0);
    }
  }

  async analyzeEnhanced(text: string, options: any = {}): Promise<SpacyFullAnalysis & { embeddings: number[] }> {
    const analysis = await this.processText(text, options);
    const embeddings = await this.embed(text);
    return { ...analysis, embeddings };
  }
}

// Singleton instance
export const spacyClient = new SpacyService();
export { SpacyService as SpacyClient };
export { CLIENT_VERSION };
export default spacyClient;