// api/_lib/services/spacyBridge.ts
// Thin bridge that adapts the local spacyClient output to a compact, stable shape
// expected by toneAnalysis.ts (spacyLite). Fully serverless and fast.

import { logger } from '../logger';
import { spacyClient } from './spacyClient';

// Helper functions for serverless-safe processing
function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}

function sat(n: number, k = 3): number {
  return Math.min(n, k) + Math.max(0, Math.log(1 + Math.max(0, n - k)) * 0.5);
}

function safeNumber(x: unknown, fallback = 0): number {
  return typeof x === 'number' && Number.isFinite(x) ? x : fallback;
}

// -----------------------------
// Enhanced Types with strict interfaces for serverless safety
// -----------------------------
interface SpacyToken {
  text?: string;
  lemma?: string;
  pos?: string;
  index?: number;
  start?: number;
  end?: number;
  tag?: string;
  dep?: string;
  sent_id?: number;
}

interface SpacySentence {
  start?: number;
  end?: number;
}

interface SpacyDependency {
  head?: number;
  rel?: string;
}

interface SpacySubtreeSpan {
  start: number;
  end: number;
}

interface SpacySarcasm {
  present?: boolean;
  score?: number;
}

interface SpacyContext {
  label?: string;
  score?: number;
}

interface SpacyPhraseEdges {
  hits?: string[];
}

// Raw spaCy client result interface
interface RawSpacyResult {
  tokens?: SpacyToken[];
  sents?: SpacySentence[];
  deps?: SpacyDependency[];
  subtreeSpan?: Record<number, SpacySubtreeSpan>;
  sarcasm?: SpacySarcasm;
  context?: SpacyContext;
  phraseEdges?: SpacyPhraseEdges;
}

// Compact document interfaces for output (already defined below)

// Alternative raw spaCy client result interface
interface SpacyResult {
  tokens?: SpacyToken[];
  sents?: Array<{ start?: number; end?: number }>;
  deps?: Array<{ head?: number; rel?: string }>;
  subtreeSpan?: Record<number, { start: number; end: number }>;
  sarcasm?: { present?: boolean; score?: number };
  context?: { label?: string; score?: number };
  phraseEdges?: { hits?: string[] };
}

export interface CompactToken {
  text: string;
  lemma: string;
  pos: string;
  i: number;
  // Optional char offsets if the client provides them (recommended)
  start?: number;
  end?: number;
  tag?: string;
  dep?: string;
  sent_id?: number;
}

export interface CompactDoc {
  version: string; // contract version
  tokens: CompactToken[];
  sents: Array<{ start: number; end: number }>; // CHAR spans (inclusive-exclusive)
  deps: Array<{ head?: number; rel?: string }>;
  subtreeSpan: Record<number, { start: number; end: number }>; // CHAR span of head's subtree
  sarcasm: { present: boolean; score: number };
  context: { label: string; score: number };
  phraseEdges: string[];

  // New, computed here:
  negScopes: Array<{ start: number; end: number }>; // TOKEN spans (inclusive)
  entities: Array<{ label: string; start: number; end: number }>; // TOKEN spans
}

// -----------------------------
// Helpers
// -----------------------------

/** Enhanced merge function with type safety and bounds checking */
function mergeTokenSpans(
  spans: Array<{ start: number; end: number }>
): Array<{ start: number; end: number }> {
  if (!Array.isArray(spans) || spans.length === 0) return [];
  
  // Validate and sanitize spans
  const validSpans = spans
    .filter(s => s && typeof s.start === 'number' && typeof s.end === 'number')
    .map(s => ({
      start: Math.max(0, Math.floor(safeNumber(s.start))),
      end: Math.max(0, Math.floor(safeNumber(s.end)))
    }))
    .filter(s => s.start <= s.end); // Remove invalid ranges

  if (validSpans.length === 0) return [];

  validSpans.sort((a, b) => (a.start - b.start) || (a.end - b.end));
  const out: Array<{ start: number; end: number }> = [];
  let cur = { ...validSpans[0] };
  
  for (let i = 1; i < validSpans.length; i++) {
    const s = validSpans[i];
    if (s.start <= cur.end + 1) {
      cur.end = Math.max(cur.end, s.end);
    } else {
      out.push(cur); 
      cur = { ...s };
    }
  }
  out.push(cur);
  
  // Apply saturation to prevent excessive span count
  const saturatedCount = sat(out.length, 10);
  return out.slice(0, Math.floor(saturatedCount));
}

/** Map a CHAR span to a TOKEN span using token start/end if present; fallback to heuristic with bounds checking. */
function charSpanToTokenSpan(
  charStart: number,
  charEnd: number,
  tokens: CompactToken[],
  sentsChar: Array<{ start: number; end: number }>
): { start: number; end: number } | null {
  if (!tokens?.length) return null;

  const cs = Math.max(0, Math.min(charStart, charEnd));
  const ce = Math.max(cs, Math.max(charStart, charEnd));

  const haveOffsets = tokens.every(t => typeof t.start === 'number' && typeof t.end === 'number');
  if (haveOffsets) {
    let tStart = 0, tEnd = tokens.length - 1;
    for (let i = 0; i < tokens.length; i++) {
      if ((tokens[i].end ?? 0) > cs) { tStart = i; break; }
    }
    for (let i = tStart; i < tokens.length; i++) {
      if ((tokens[i].start ?? 0) >= ce) { tEnd = Math.max(tStart, i - 1); break; }
      tEnd = i;
    }
    return { start: tStart, end: tEnd };
  }

  // Fallback without offsets: cover a small window in the sentence
  const sent = sentsChar.find(s => cs >= (s.start ?? 0) && cs < (s.end ?? 0)) ?? sentsChar[0];
  if (!sent) return { start: 0, end: Math.min(tokens.length - 1, 20) };
  const approx = Math.min(tokens.length, 20);
  return { start: 0, end: approx - 1 };
}

/** Compute negation scopes as TOKEN spans using deps + subtreeSpan with fallbacks. */
function computeNegScopes(
  deps: Array<{ head?: number; rel?: string }>,
  subtreeSpan: Record<number, { start: number; end: number }>,
  tokens: CompactToken[],
  sentsChar: Array<{ start: number; end: number }>
): Array<{ start: number; end: number }> {
  if (!Array.isArray(deps) || !Array.isArray(tokens)) {
    return [];
  }

  const MAX_NEG_TOKENS = 40;
  const spans: Array<{ start: number; end: number }> = [];
  const maxDeps = Math.min(deps.length, 200); // Cap dependency processing for serverless

  for (let i = 0; i < maxDeps; i++) {
    const d = deps[i];
    if (!d || d.rel !== 'neg') continue;
    const head = typeof d.head === 'number' ? Math.max(0, d.head) : -1;
    if (head < 0 || head >= tokens.length) continue;

    const sub = subtreeSpan?.[head];
    if (sub && typeof sub.start === 'number' && typeof sub.end === 'number') {
      const ts = charSpanToTokenSpan(sub.start, sub.end, tokens, sentsChar);
      if (ts) {
        // Cap negation scope width after merge
        if (ts.end - ts.start + 1 > MAX_NEG_TOKENS) {
          ts.end = ts.start + MAX_NEG_TOKENS - 1;
        }
        spans.push(ts);
      }
      continue;
    }

    // Fallback: use sentence containing head token
    const headTok = tokens.find(t => safeNumber(t.i) === head);
    if (headTok && typeof headTok.start === 'number' && typeof headTok.end === 'number') {
      const ts = charSpanToTokenSpan(headTok.start, headTok.end, tokens, sentsChar);
      if (ts) {
        // Cap negation scope width after merge
        if (ts.end - ts.start + 1 > MAX_NEG_TOKENS) {
          ts.end = ts.start + MAX_NEG_TOKENS - 1;
        }
        spans.push(ts);
      }
    } else {
      // Last resort: reasonable bounds, not whole token stream
      const maxTokens = Math.min(tokens.length, 50); // Cap scope size
      const scopeStart = Math.max(0, head - 5);
      const scopeEnd = Math.min(head + 5, maxTokens - 1);
      if (scopeStart < scopeEnd) {
        const span = { start: scopeStart, end: scopeEnd };
        // Cap negation scope width after merge
        if (span.end - span.start + 1 > MAX_NEG_TOKENS) {
          span.end = span.start + MAX_NEG_TOKENS - 1;
        }
        spans.push(span);
      }
    }
  }

  const merged = mergeTokenSpans(spans);
  // Apply saturation to prevent excessive negation scopes
  const saturatedCount = sat(merged.length, 8);
  return merged.slice(0, Math.floor(saturatedCount));
}

/** Extract simple second-person entities as TOKEN spans (PRON_2P). */
function extractSecondPersonEntities(tokens: CompactToken[]): Array<{ label: string; start: number; end: number }> {
  if (!Array.isArray(tokens)) {
    return [];
  }

  const out: Array<{ label: string; start: number; end: number }> = [];
  const SECOND = new Set(['you', 'your', "you're", 'ur', 'u', 'yours', 'yourself', "youre"]);
  
  // Apply saturation to prevent spam detection
  let matchCount = 0;
  const maxMatches = 20; // Reasonable limit
  
  for (const t of tokens) {
    if (matchCount >= maxMatches) break;
    
    const lem = (t.lemma || t.text || '').toLowerCase().trim();
    if (SECOND.has(lem)) {
      const tokenIndex = safeNumber(t.i);
      out.push({ 
        label: 'PRON_2P', 
        start: tokenIndex, 
        end: tokenIndex 
      });
      matchCount++;
    }
  }
  
  // Merge adjacent spans while preserving labels
  const spans = out.map(e => ({ start: e.start, end: e.end }));
  const merged = mergeTokenSpans(spans);
  const mergedEff = sat(merged.length, 5); // Apply saturation to merged count
  
  return merged.slice(0, Math.floor(mergedEff)).map(span => ({ 
    label: 'PRON_2P', 
    start: Math.max(0, span.start), 
    end: Math.max(0, span.end) 
  }));
}

// Shape adaptation with enhanced error handling and strict typing
function toCompact(text: string, result: SpacyResult): CompactDoc {
  if (!result || typeof result !== 'object') {
    logger.warn('Invalid spaCy result, using fallback');
    return createFallbackDoc(text);
  }

  const rawTokens = Array.isArray(result.tokens) ? result.tokens : [];
  const tokens: CompactToken[] = rawTokens.map((t: SpacyToken, idx: number) => ({
    text: typeof t?.text === 'string' ? t.text : '',
    lemma: (typeof t?.lemma === 'string' ? t.lemma : (typeof t?.text === 'string' ? t.text : '')).toLowerCase(),
    pos: String(t?.pos ?? 'X').toUpperCase(),
    i: safeNumber(t?.index ?? idx),
    start: typeof t?.start === 'number' ? Math.max(0, t.start) : undefined,
    end: typeof t?.end === 'number' ? Math.max(0, t.end) : undefined,
    tag: typeof t?.tag === 'string' ? t.tag : undefined,
    dep: typeof t?.dep === 'string' ? t.dep : undefined,
    sent_id: typeof t?.sent_id === 'number' ? Math.max(0, t.sent_id) : undefined
  }));

  const textLength = (text || '').length;
  const sentsChar: Array<{ start: number; end: number }> =
    (Array.isArray(result.sents) && result.sents.length)
      ? result.sents.map(s => ({
          start: Math.max(0, safeNumber(s?.start)),
          end: Math.min(textLength, safeNumber(s?.end, textLength))
        }))
      : [{ start: 0, end: textLength }];

  const deps = (Array.isArray(result.deps) ? result.deps : []).map((d: any) => ({ 
    head: typeof d?.head === 'number' ? Math.max(0, d.head) : undefined, 
    rel: typeof d?.rel === 'string' ? d.rel : undefined 
  }));
  
  const subtreeSpan = (result.subtreeSpan && typeof result.subtreeSpan === 'object') ? result.subtreeSpan : {};

  // --- New computed fields ---
  const negScopes = computeNegScopes(deps, subtreeSpan, tokens, sentsChar);
  const entities = extractSecondPersonEntities(tokens);

  const compact: CompactDoc = {
    version: '1.2.0',
    tokens,
    sents: sentsChar,
    deps,
    subtreeSpan,
    sarcasm: { 
      present: !!result.sarcasm?.present, 
      score: clamp01(safeNumber(result.sarcasm?.score)) 
    },
    context: { 
      label: typeof result.context?.label === 'string' ? result.context.label : 'general', 
      score: clamp01(safeNumber(result.context?.score, 0.1))
    },
    phraseEdges: Array.isArray(result.phraseEdges?.hits) ? 
      result.phraseEdges.hits.filter((h): h is string => typeof h === 'string').slice(0, 50) : [], // Cap phrase edges
    negScopes,
    entities
  };

  return compact;
}

function createFallbackDoc(text: string): CompactDoc {
  return {
    version: '1.2.0',
    tokens: [],
    sents: [{ start: 0, end: (text || '').length }],
    deps: [],
    subtreeSpan: {},
    sarcasm: { present: false, score: 0 },
    context: { label: 'general', score: 0.1 },
    phraseEdges: [],
    negScopes: [],
    entities: []
  };
}

// Enhanced public API with comprehensive error handling
export async function processWithSpacy(text: string, _mode?: string): Promise<CompactDoc> {
  try {
    if (!text || typeof text !== 'string') {
      logger.warn('Invalid text input, using fallback');
      return createFallbackDoc('');
    }

    // Apply text length limits for serverless performance
    const safeText = text.length > 10000 ? text.slice(0, 10000) : text;
    
    const t0 = Date.now();
    const r = spacyClient.process(safeText);
    const compact = toCompact(safeText, r);
    const dt = Date.now() - t0;
    
    if (dt > 5000) { // Log slow processing for monitoring
      logger.warn(`Slow spaCy processing: ${dt}ms for ${safeText.length} chars`);
    }
    
    logger.debug(`spaCy helper processed ${safeText.length} chars in ${dt.toFixed(2)} ms`);
    return compact;
  } catch (error) {
    logger.error('spaCy processing failed:', error);
    return createFallbackDoc(text || '');
  }
}

export function processWithSpacySync(text: string, _mode?: string): CompactDoc {
  try {
    if (!text || typeof text !== 'string') {
      logger.warn('Invalid text input (sync), using fallback');
      return createFallbackDoc('');
    }

    // Apply text length limits for serverless performance
    const safeText = text.length > 8000 ? text.slice(0, 8000) : text;
    
    const r = spacyClient.process(safeText);
    return toCompact(safeText, r);
  } catch (error) {
    logger.error('spaCy processing failed (sync):', error);
    return createFallbackDoc(text || '');
  }
}

export async function checkSpacyHealth(): Promise<boolean> {
  try {
    const testText = "Hello world.";
    const result = processWithSpacySync(testText);
    
    // Verify basic structure is present
    const isHealthy = !!(
      result && 
      result.version && 
      Array.isArray(result.tokens) && 
      Array.isArray(result.sents) &&
      typeof result.sarcasm === 'object' &&
      typeof result.context === 'object'
    );
    
    if (!isHealthy) {
      logger.warn('spaCy health check failed - invalid result structure');
    }
    
    return isHealthy;
  } catch (error) {
    logger.error('spaCy health check failed:', error);
    return false;
  }
}
