// api/_lib/services/adviceIndex.ts
import { dataLoader } from './dataLoader';
import { BM25 } from './bm25';
import { spacyClient } from './spacyClient';
import { logger } from '../logger';
import { isContextAppropriate, getContextLinkBonus } from './contextAnalysis';
import type { TherapyAdvice } from '../types/dataTypes';


// Helper functions for serverless-safe processing
function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}

function sat(n: number, k = 3): number {
  return Math.min(n, k) + Math.max(0, Math.log(1 + Math.max(0, n - k)) * 0.5);
}

// Safe concurrency limiter with proper error handling
async function pLimit<T>(limit: number, tasks: (() => Promise<T>)[]): Promise<T[]> {
  if (!Array.isArray(tasks) || limit <= 0) {
    return [];
  }

  const results: Promise<T>[] = [];
  const executing: Promise<void>[] = [];
  let i = 0;

  const run = async (): Promise<void> => {
    const idx = i++;
    if (idx >= tasks.length) return;
    
    try {
      results[idx] = tasks[idx]();
    } catch (e) {
      results[idx] = Promise.reject(e);
    }
    
    const done = results[idx].then(
      () => { const i = executing.indexOf(done); if (i >= 0) executing.splice(i, 1); },
      () => { const i = executing.indexOf(done); if (i >= 0) executing.splice(i, 1); }
    );
    executing.push(done);
    
    if (executing.length >= limit) {
      await Promise.race(executing);
    }
    
    await run();
  };

  try {
    await run();
    await Promise.allSettled(executing);
    
    const settled = await Promise.allSettled(results);
    return settled.map(s => {
      if (s.status === 'fulfilled') {
        return s.value;
      } else {
        logger.debug('Task failed in pLimit:', s.reason);
        return null as any; // Return null for failed tasks
      }
    }).filter(v => v !== null);
  } catch (error) {
    logger.error('pLimit execution failed:', error);
    return [];
  }
}

export async function initAdviceSearch(): Promise<void> {
  logger.info('Initializing advice search index...');

  // ✅ Use normalized items with proper fallback handling
  const items: TherapyAdvice[] = (() => {
    try {
      // Try dataLoader enhanced method first
      if (typeof (dataLoader as any).getAllAdviceItems === 'function') {
        return (dataLoader as any).getAllAdviceItems();
      }
      
      // Try named export fallback
      if (dataLoader && typeof dataLoader.getAllAdviceItems === 'function') {
        return dataLoader.getAllAdviceItems();
      }
      
      // Last resort: raw data extraction with defensive parsing
      const raw = dataLoader.get('therapyAdvice');
      if (!raw) {
        logger.warn('No therapy advice data found in dataLoader');
        return [];
      }
      
      const arr = Array.isArray(raw?.items) ? raw.items : Array.isArray(raw) ? raw : [];
      return arr.filter((item: any) => 
        item && 
        typeof item === 'object' && 
        typeof item.id === 'string' && 
        typeof item.advice === 'string'
      ) as TherapyAdvice[];
    } catch (e) {
      logger.error('Failed to load advice items:', e);
      return [];
    }
  })();

  if (!Array.isArray(items) || items.length === 0) {
    logger.warn('No therapy advice items found for indexing');
    // still attach empty handles so callers don’t explode
    attachIndexHandles([], new Map(), null);
    return;
  }

  // Filter obviously broken rows (defensive)
  const cleaned = deDupeById(
    items.filter(it => typeof it?.id === 'string' && it.id && typeof it?.advice === 'string' && it.advice.trim().length > 0)
  );

  logger.info(`Building search index for ${cleaned.length}/${items.length} valid advice items`);

  // Helper function to dedupe arrays
  const uniq = <T,>(arr: T[] = []) => Array.from(new Set(arr));

  // Build plain-text field for each item (include keywords to improve recall)
  const docs = cleaned.map((it) => ({
    id: it.id,
    text: [
      it.advice,
      ...uniq(it.contexts || []),
      ...uniq(it.attachmentStyles || []),
      ...uniq(it.boostSources || []),
      ...uniq((it as any).tags || []),           // ← add this line
      ...uniq((it as any).keywords || [])
    ].filter(Boolean).join(' ')
  }));

  // BM25 in-memory index
  const bm25 = new BM25(docs);

  // Lazy vector cache + on-demand embedding
  const vecCache = new Map<string, Float32Array>();

  // Attach to dataLoader for suggestions.ts (and others) to reuse
  attachIndexHandles(cleaned, vecCache, bm25);

  logger.info('BM25 index built successfully');

  // Warm vector cache (guarded + bounded)
  const DISABLE_WARM = process.env.ADVICE_WARM_DISABLE === '1';
  const WARM_MAX = Number(process.env.ADVICE_WARM_MAX || 200);
  const WARM_CONCURRENCY = Number(process.env.ADVICE_WARM_CONCURRENCY || 4);

  if (DISABLE_WARM || cleaned.length === 0) {
    logger.info('Vector cache warming skipped (disabled or empty)');
    return;
  }

  try {
    await warmAdviceVectors(cleaned, vecCache, WARM_MAX, WARM_CONCURRENCY);
    logger.info('Vector cache warmed successfully');
  } catch (error) {
    logger.warn('Vector cache warming failed:', error);
  }
}

function deDupeById<T extends { id: string }>(arr: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const it of arr) {
    if (seen.has(it.id)) continue;
    seen.add(it.id);
    out.push(it);
  }
  return out;
}

function attachIndexHandles(items: TherapyAdvice[], vecCache: Map<string, Float32Array>, bm25: BM25 | null) {
  (dataLoader as any).adviceBM25 = bm25;
  (dataLoader as any).adviceIndexItems = Array.isArray(items) ? items : []; // Ensure array

  // Sync getter used by suggestions.ts (cache only)
  const syncVectorGetter = (id: string): Float32Array | null => {
    const v = vecCache.get(id);
    return v ? v.slice() : null;
  };
  
  (dataLoader as any).adviceGetVector = syncVectorGetter;

  // Optional async warmer for callers that want to fill the cache
  (dataLoader as any).adviceWarmVector = async (id: string): Promise<boolean> => {
    if (vecCache.has(id)) return true;
    
    const item = items.find(i => i?.id === id);
    if (!item?.advice?.trim()) return false;
    
    try {
      const v = await spacyClient.embed(item.advice.trim());
      if (!Array.isArray(v) || !v.length) return false;
      vecCache.set(id, new Float32Array(v));
      return true;
    } catch {
      return false;
    }
  };

  // Defensive dual-register for loaders that use .set()
  if (typeof (dataLoader as any).set === 'function') {
    (dataLoader as any).set('adviceBM25', bm25);
    (dataLoader as any).set('adviceIndexItems', items);
    (dataLoader as any).set('adviceGetVector', syncVectorGetter);
  }
}

async function warmAdviceVectors(
  items: TherapyAdvice[],
  cache: Map<string, Float32Array>,
  max = 200,
  concurrency = 4
): Promise<void> {
  const safeMax = Math.floor(clamp01(max / 1000) * 1000); // Fix: prevent fractional slice
  const safeConcurrency = Math.min(Math.max(1, concurrency), 10); // Limit concurrency
  const subset = items.slice(0, Math.max(0, safeMax));
  
  logger.info(`Warming vector cache for ${subset.length} items (concurrency=${safeConcurrency})...`);

  const tasks = subset.map((it) => async () => {
    if (!it?.id || !it?.advice) {
      return { id: it?.id || 'unknown', ok: false, reason: 'missing_data' };
    }

    const text = (it.advice || '').trim()
      || [...(it.contexts || []), ...(it.attachmentStyles || [])].filter(Boolean).join(' ').trim();
      
    if (!text) {
      return { id: it.id, ok: false, reason: 'no_text' };
    }

    try {
      const v = await spacyClient.embed(text);
      if (!Array.isArray(v) || v.length === 0) {
        return { id: it.id, ok: false, reason: 'invalid_embedding' };
      }
      
      cache.set(it.id, new Float32Array(v));
      return { id: it.id, ok: true, reason: 'success' };
    } catch (error) {
      logger.debug(`Failed to embed vector for advice ${it.id}:`, error);
      return { id: it.id, ok: false, reason: 'embed_error' };
    }
  });

  try {
    const results = await pLimit(safeConcurrency, tasks);
    const ok = results.filter(r => r?.ok).length;
    const failed = results.filter(r => !r?.ok);
    
    logger.info(`Vector cache warmed: ${ok}/${subset.length} vectors cached`);
    if (failed.length > 0) {
      const reasons = failed.reduce((acc: Record<string, number>, r) => {
        const reason = r?.reason || 'unknown';
        acc[reason] = (acc[reason] || 0) + 1;
        return acc;
      }, {});
      logger.debug('Embedding failures by reason:', reasons);
    }
  } catch (error) {
    logger.error('Vector warming failed:', error);
  }
  
}

// additive – returns ranked micro-advice for the request context, tone & ctxScores
export async function getAdviceCandidates(opts: {
  requestCtx: string;                  // normalized context
  ctxScores: Record<string, number>;   // includes *.pattern keys
  triggerTone: 'clear'|'caution'|'alert';
  limit?: number;                      // default 6-8
  tryGetAttachmentEstimate?: () => { primary?: 'anxious'|'avoidant'|'disorganized'|'secure'; confidence?: number } | null;
}) {
  const { requestCtx, ctxScores, triggerTone, limit = 8, tryGetAttachmentEstimate } = opts;

  const items = (dataLoader as any).adviceIndexItems as TherapyAdvice[] || [];
  const bm25 = (dataLoader as any).adviceBM25 as BM25 | null;

  // 1) filter by tone + context (reuse isContextAppropriate)
  const filtered = items.filter(it => {
    // Fix: normalize tone matching to handle arrays and exact match
    const toneOk = (() => {
      if (!it.triggerTone) return true;
      const tones = Array.isArray(it.triggerTone) ? it.triggerTone : [it.triggerTone];
      return tones.includes(triggerTone);
    })();
    if (!toneOk) return false;
    
    return isContextAppropriate(it as any, requestCtx, ctxScores);
  });

  // 2) Build single BM25 query from request context + top signals (with weighting)
  const topCtx = Object.entries(ctxScores).sort((a,b)=>b[1]-a[1]).slice(0,3).map(([k])=>k);
  const query = [requestCtx, requestCtx, triggerTone, ...topCtx].filter(Boolean).join(' '); // Repeat requestCtx for better ranking
  
  const bmHits = bm25 ? bm25.search(query, { limit: 1000 }) : [];
  const bmScoreById = bm25 ? new Map(bmHits.map(h => [h.id, h.score])) : new Map<string, number>();

  // 3) Score each filtered item efficiently
  const scored = filtered
    .map(it => {
      let score = 0;

      // BM25 score (single lookup instead of per-item query)
      score += (bmScoreById.get(it.id) ?? 0) * 0.55;

      // context link bonus
      score += getContextLinkBonus(it as any, topCtx); // +0.05 max

      // pattern alignment bonus (up to +0.15) - safer division
      const patterns = Array.isArray(it.patterns) ? it.patterns : [];
      const patBonus = patterns.length
        ? patterns.reduce((acc, p) => acc + Math.min(ctxScores[p] || 0, 0.15 / patterns.length), 0)
        : 0;
      score += patBonus;

      // style tuning (if we have an attachment primary with decent confidence)
      const est = tryGetAttachmentEstimate?.(); // wire from coordinator via closure if needed
      if (est?.primary && it.styleTuning?.[est.primary]) {
        score += (it.styleTuning[est.primary] || 0);
      }

      // severity gate - clearer threshold check
      const thr = it.severityThreshold?.[triggerTone];
      if (typeof thr === 'number') {
        const toneScore = ctxScores[triggerTone] || 0;
        if (toneScore < thr) score -= 0.1; // soft gate as intended
      }

      return { item: it, score };
    })
    .sort((a, b) => (b.score - a.score) || (a.item.id > b.item.id ? 1 : -1)) // Stable sorting with tie-break
    .slice(0, limit);

  return scored.map(s => s.item);
}
