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
    
    const done = results[idx].then(() => void 0, () => void 0);
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

  // Build plain-text field for each item (include keywords to improve recall)
  const docs = cleaned.map((it) => ({
    id: it.id,
    text: [
      it.advice,
      ...(it.contexts || []),
      ...(it.attachmentStyles || []),
      ...(it.boostSources || []),
      ...(Array.isArray((it as any).keywords) ? (it as any).keywords : [])
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
  (dataLoader as any).adviceIndexItems = items;

  // Expose a safe, cached embedding getter (warm or compute on-demand)
  (dataLoader as any).adviceGetVector = async (id: string): Promise<Float32Array | null> => {
    if (!id || typeof id !== 'string') {
      logger.debug('Invalid advice ID provided for vector lookup');
      return null;
    }

    const cached = vecCache.get(id);
    if (cached) return cached.slice();

    const item = items.find(i => i?.id === id);
    if (!item) {
      logger.debug(`Advice item not found: ${id}`);
      return null;
    }

    const text = item.advice ||
      [...(item.contexts || []), ...(item.attachmentStyles || [])].filter(Boolean).join(' ') ||
      '';
    if (!text.trim()) {
      logger.debug(`No text content for advice item: ${id}`);
      return null;
    }

    try {
      const v = await spacyClient.embed(text);
      if (!Array.isArray(v) || v.length === 0) {
        logger.debug(`Invalid embedding result for ${id}`);
        return null;
      }
      
      const fv = new Float32Array(v);
      vecCache.set(id, fv);
      return fv.slice();
    } catch (err) {
      logger.debug(`On-demand embed failed for ${id}:`, err);
      return null;
    }
  };
}

async function warmAdviceVectors(
  items: TherapyAdvice[],
  cache: Map<string, Float32Array>,
  max = 200,
  concurrency = 4
): Promise<void> {
  const safeMax = clamp01(max / 1000) * 1000; // Clamp to reasonable range
  const safeConcurrency = Math.min(Math.max(1, concurrency), 10); // Limit concurrency
  const subset = items.slice(0, Math.max(0, safeMax));
  
  logger.info(`Warming vector cache for ${subset.length} items (concurrency=${safeConcurrency})...`);

  const tasks = subset.map((it) => async () => {
    if (!it?.id || !it?.advice) {
      return { id: it?.id || 'unknown', ok: false, reason: 'missing_data' };
    }

    const text = it.advice.trim() ||
      [...(it.contexts || []), ...(it.attachmentStyles || [])].filter(Boolean).join(' ').trim() ||
      '';
      
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
  const scored = items
    .filter(it => {
      if (it.triggerTone && it.triggerTone !== triggerTone) return false;
      return isContextAppropriate(it as any, requestCtx, ctxScores);
    })
    .map(it => {
      // 2) score blend: bm25(text) + context link + pattern alignment + style tuning
      let score = 0;

      if (bm25) {
        const q = [
          requestCtx,
          triggerTone,
          ...(it.contexts || []),
          ...(it.patterns || []),
          ...(it.attachmentStyles || []),
          ...(it.tags || [])
        ].join(' ');
        const results = bm25.search(q, { limit: 100 }); // search all, we'll filter later
        const matchingResult = results.find(r => r.id === it.id);
        if (matchingResult) {
          score += matchingResult.score * 0.55;
        }
      }

      // context link bonus
      const topCtx = Object.entries(ctxScores).sort((a,b)=>b[1]-a[1]).slice(0,3).map(([k])=>k);
      score += getContextLinkBonus(it as any, topCtx); // +0.05 max

      // pattern alignment bonus (up to +0.15)
      const patBonus = (it.patterns || []).reduce((acc, p) => {
        const v = ctxScores[p] || 0;
        return acc + Math.min(v, 0.15/ (it.patterns?.length || 1));
      }, 0);
      score += patBonus;

      // style tuning (if we have an attachment primary with decent confidence)
      const est = tryGetAttachmentEstimate?.(); // wire from coordinator via closure if needed
      if (est?.primary && it.styleTuning?.[est.primary]) {
        score += (it.styleTuning[est.primary] || 0);
      }

      // severity gate
      if (it.severityThreshold?.[triggerTone] != null) {
        const thr = Number(it.severityThreshold[triggerTone]);
        const toneScore = (ctxScores[`${triggerTone}`] || 0); // optional if you track per-bucket
        if (toneScore < thr) score -= 0.1;                     // soft gate, not hard filter
      }

      return { item: it, score };
    })
    .sort((a,b)=> b.score - a.score)
    .slice(0, limit);

  return scored.map(s => s.item);
}
