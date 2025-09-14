// api/_lib/services/spacyBridge.ts
// Thin bridge that adapts the local spacyClient output to a compact, stable shape
// expected by toneAnalysis.ts (spacyLite). Fully serverless and fast.

import { logger } from '../logger';
import { spacyClient } from './spacyClient';

// -----------------------------
// Types
// -----------------------------
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
  sarcasm: { present: boolean; score?: number };
  context: { label: string; score: number };
  phraseEdges: string[];

  // New, computed here:
  negScopes: Array<{ start: number; end: number }>; // TOKEN spans (inclusive)
  entities: Array<{ label: string; start: number; end: number }>; // TOKEN spans
}

// -----------------------------
// Helpers
// -----------------------------

/** Merge overlapping/adjacent token spans in-place. */
function mergeTokenSpans(
  spans: Array<{ start: number; end: number }>
): Array<{ start: number; end: number }> {
  if (spans.length === 0) return spans;
  spans.sort((a, b) => (a.start - b.start) || (a.end - b.end));
  const out: Array<{ start: number; end: number }> = [];
  let cur = { ...spans[0] };
  for (let i = 1; i < spans.length; i++) {
    const s = spans[i];
    if (s.start <= cur.end + 1) {
      cur.end = Math.max(cur.end, s.end);
    } else {
      out.push(cur); cur = { ...s };
    }
  }
  out.push(cur);
  return out;
}

/** Map a CHAR span to a TOKEN span using token start/end if present; fallback to heuristic. */
function charSpanToTokenSpan(
  charStart: number,
  charEnd: number,
  tokens: CompactToken[],
  sentsChar: Array<{ start: number; end: number }>
): { start: number; end: number } | null {
  if (tokens.length === 0) return null;

  // Prefer exact mapping when token char offsets exist
  const haveOffsets = tokens.every(t => typeof t.start === 'number' && typeof t.end === 'number');
  if (haveOffsets) {
    let tStart = -1, tEnd = -1;
    for (const t of tokens) {
      if (tStart === -1 && (t.start as number) >= charStart) tStart = t.i;
      if ((t.end as number) <= charEnd) tEnd = t.i;
    }
    if (tStart === -1) tStart = 0;
    if (tEnd === -1) tEnd = tokens[tokens.length - 1].i;
    if (tStart > tEnd) [tStart, tEnd] = [tEnd, tStart];
    return { start: tStart, end: tEnd };
  }

  // Heuristic fallback: bound by the sentence that contains charStart
  const sent = sentsChar.find(s => charStart >= s.start && charStart < s.end) ?? sentsChar[0];
  if (!sent) return { start: 0, end: Math.max(0, tokens.length - 1) };
  // Without char offsets, approximate by covering the entire sentence in token indices
  const sentStartTok = 0;
  const sentEndTok = tokens.length - 1;
  return { start: sentStartTok, end: sentEndTok };
}

/** Compute negation scopes as TOKEN spans using deps + subtreeSpan with fallbacks. */
function computeNegScopes(
  deps: Array<{ head?: number; rel?: string }>,
  subtreeSpan: Record<number, { start: number; end: number }>,
  tokens: CompactToken[],
  sentsChar: Array<{ start: number; end: number }>
): Array<{ start: number; end: number }> {
  const spans: Array<{ start: number; end: number }> = [];

  for (const d of deps) {
    if (!d || d.rel !== 'neg') continue;
    const head = typeof d.head === 'number' ? d.head! : -1;
    if (head < 0) continue;

    const sub = subtreeSpan[head];
    if (sub && typeof sub.start === 'number' && typeof sub.end === 'number') {
      const ts = charSpanToTokenSpan(sub.start, sub.end, tokens, sentsChar);
      if (ts) spans.push(ts);
      continue;
    }

    // Fallback: use sentence containing head token
    const headTok = tokens.find(t => t.i === head);
    if (headTok && typeof headTok.start === 'number' && typeof headTok.end === 'number') {
      const ts = charSpanToTokenSpan(headTok.start!, headTok.end!, tokens, sentsChar);
      if (ts) spans.push(ts);
    } else {
      // Last resort: whole token stream
      spans.push({ start: 0, end: Math.max(0, tokens.length - 1) });
    }
  }

  return mergeTokenSpans(spans);
}

/** Extract simple second-person entities as TOKEN spans (PRON_2P). */
function extractSecondPersonEntities(tokens: CompactToken[]): Array<{ label: string; start: number; end: number }> {
  const out: Array<{ label: string; start: number; end: number }> = [];
  const SECOND = new Set(['you', 'your', "you're", 'ur', 'u', 'yours', 'yourself', "youre"]);
  for (const t of tokens) {
    const lem = (t.lemma || t.text || '').toLowerCase();
    if (SECOND.has(lem)) out.push({ label: 'PRON_2P', start: t.i, end: t.i });
  }
  
  // Merge adjacent spans while preserving labels
  const spans = out.map(e => ({ start: e.start, end: e.end }));
  const merged = mergeTokenSpans(spans);
  return merged.map(span => ({ label: 'PRON_2P', start: span.start, end: span.end }));
}

// -----------------------------
// Shape adaptation
function toCompact(text: string, result: ReturnType<typeof spacyClient.process>): CompactDoc {
  const rawTokens = Array.isArray(result.tokens) ? result.tokens : [];
  const tokens: CompactToken[] = rawTokens.map((t: any, idx: number) => ({
    text: t.text ?? '',
    lemma: (t.lemma ?? t.text ?? '').toLowerCase(),
    pos: String(t.pos ?? 'X').toUpperCase(),
    i: Number(t.index ?? idx),
    start: typeof t.start === 'number' ? t.start : undefined,
    end: typeof t.end === 'number' ? t.end : undefined,
    tag: t.tag ?? undefined,
    dep: t.dep ?? undefined,
    sent_id: typeof t.sent_id === 'number' ? t.sent_id : undefined
  }));

  const sentsChar: Array<{ start: number; end: number }> =
    (Array.isArray(result.sents) && result.sents.length)
      ? result.sents
      : [{ start: 0, end: text.length }];

  const deps = (result.deps || []).map((d: any) => ({ head: d.head, rel: d.rel }));
  const subtreeSpan = result.subtreeSpan || {};

  // --- New computed fields ---
  const negScopes = computeNegScopes(deps, subtreeSpan, tokens, sentsChar);
  const entities = extractSecondPersonEntities(tokens);

  const compact: CompactDoc = {
    version: '1.2.0',
    tokens,
    sents: sentsChar,
    deps,
    subtreeSpan,
    sarcasm: { present: !!result.sarcasm?.present, score: Number(result.sarcasm?.score || 0) },
    context: { label: result.context?.label || 'general', score: Number(result.context?.score || 0.1) },
    phraseEdges: Array.isArray(result.phraseEdges?.hits) ? result.phraseEdges!.hits : [],
    negScopes,
    entities
  };

  return compact;
}

// -----------------------------
// Public API
// -----------------------------
export async function processWithSpacy(text: string, _mode?: string): Promise<CompactDoc> {
  try {
    const t0 = Date.now();
    const r = spacyClient.process(text ?? '');
    const compact = toCompact(text ?? '', r);
    const dt = Date.now() - t0;
    logger.debug(`spaCy helper processed ${text.length} chars in ${dt.toFixed(2)} ms`);
    return compact;
  } catch (error) {
    logger.error('spaCy processing failed:', error);
    return {
      version: '1.2.0',
      tokens: [],
      sents: [{ start: 0, end: (text ?? '').length }],
      deps: [],
      subtreeSpan: {},
      sarcasm: { present: false, score: 0 },
      context: { label: 'general', score: 0.1 },
      phraseEdges: [],
      negScopes: [],
      entities: []
    };
  }
}

export function processWithSpacySync(text: string, _mode?: string): CompactDoc {
  try {
    const r = spacyClient.process(text ?? '');
    return toCompact(text ?? '', r);
  } catch (error) {
    logger.error('spaCy processing failed (sync):', error);
    return {
      version: '1.2.0',
      tokens: [],
      sents: [{ start: 0, end: (text ?? '').length }],
      deps: [],
      subtreeSpan: {},
      sarcasm: { present: false, score: 0 },
      context: { label: 'general', score: 0.1 },
      phraseEdges: [],
      negScopes: [],
      entities: []
    };
  }
}

export async function checkSpacyHealth(): Promise<boolean> {
  try {
    await spacyClient.healthCheck();
    return true;
  } catch (error) {
    logger.error('spaCy health check failed:', error);
    return false;
  }
}
