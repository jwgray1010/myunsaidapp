// api/_lib/services/spacyBridge.ts
// Thin bridge that adapts the local spacyClient output to the
// compact shape expected by toneAnalysis.ts (spacyLite).
// No network, no Python — fully serverless and fast.

import { logger } from '../logger';
import { spacyClient } from './spacyClient';

export interface CompactDoc {
  tokens?: Array<{ text: string; lemma: string; pos: string; i: number }>;
  sents?: Array<{ start: number; end: number }>;
  deps?: Array<{ head?: number; rel?: string }>; // we only need rel + head for neg scopes
  subtreeSpan?: Record<number, { start: number; end: number }>; // head index -> char span
  sarcasm?: { present: boolean; score?: number };
  context?: { label: string; score: number };
  phraseEdges?: string[];
}

function toCompact(text: string, result: ReturnType<typeof spacyClient.process>): CompactDoc {
  const tokens = (result.tokens || []).map(t => ({
    text: t.text ?? '',
    lemma: (t.lemma ?? t.text ?? '').toLowerCase(),
    pos: (t.pos ?? 'X').toUpperCase(),
    i: Number(t.index ?? 0)
  }));

  const sents = (result.sents && result.sents.length)
    ? result.sents
    : [{ start: 0, end: text.length }];

  const deps = (result.deps || []).map(d => ({ head: d.head, rel: d.rel }));

  const compact: CompactDoc = {
    tokens,
    sents,
    deps,
    subtreeSpan: result.subtreeSpan || {},
    sarcasm: { present: !!result.sarcasm?.present, score: Number(result.sarcasm?.score || 0) },
    context: { label: result.context?.label || 'general', score: Number(result.context?.score || 0.1) },
    phraseEdges: Array.isArray(result.phraseEdges?.hits) ? result.phraseEdges!.hits : []
  };

  return compact;
}

// Main processing function - async-friendly (but local and sync under the hood)
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
    return { tokens: [], sents: [{ start: 0, end: (text ?? '').length }], deps: [], subtreeSpan: {}, sarcasm: { present: false, score: 0 }, context: { label: 'general', score: 0.1 }, phraseEdges: [] };
  }
}

// Synchronous version
export function processWithSpacySync(text: string, _mode?: string): CompactDoc {
  try {
    const r = spacyClient.process(text ?? '');
    return toCompact(text ?? '', r);
  } catch (error) {
    logger.error('spaCy processing failed (sync):', error);
    return { tokens: [], sents: [{ start: 0, end: (text ?? '').length }], deps: [], subtreeSpan: {}, sarcasm: { present: false, score: 0 }, context: { label: 'general', score: 0.1 }, phraseEdges: [] };
  }
}

// Health check
export async function checkSpacyHealth(): Promise<boolean> {
  try {
    await spacyClient.healthCheck();
    return true;
  } catch (error) {
    logger.error('spaCy health check failed:', error);
    return false;
  }
}