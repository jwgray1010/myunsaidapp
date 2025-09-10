// api/_lib/services/adviceIndex.ts
import { dataLoader } from './dataLoader';
import { BM25 } from './bm25';
import { spacyClient } from './spacyClient';
import { logger } from '../logger';
import type { TherapyAdvice } from '../types/dataTypes';

export async function initAdviceSearch(): Promise<void> {
  logger.info('Initializing advice search index...');
  
  const therapyAdvice = dataLoader.get('therapyAdvice');
  const items: TherapyAdvice[] = Array.isArray(therapyAdvice) ? therapyAdvice : [];
  
  if (items.length === 0) {
    logger.warn('No therapy advice items found for indexing');
    return;
  }

  logger.info(`Building search index for ${items.length} advice items`);

  // Build plain-text field for each item
  const docs = items.map((it) => ({
    id: it.id,
    text: [
      it.advice,
      ...(it.contexts || []),
      ...(it.attachmentStyles || []),
      ...(it.boostSources || [])
    ]
      .filter(Boolean)
      .join(' ')
  }));

  // BM25 in-memory index
  const bm25 = new BM25(docs);

  // Lazy vector cache
  const vecCache = new Map<string, Float32Array>();

  // Attach to dataLoader for suggestions.ts to pick up
  (dataLoader as any).adviceBM25 = bm25;
  (dataLoader as any).adviceIndexItems = items;
  (dataLoader as any).adviceGetVector = (id: string) =>
    (vecCache.get(id) || null)?.slice() || null;

  logger.info('BM25 index built successfully');

  // Warm vector cache
  try {
    await warmAdviceVectors(items, vecCache);
    logger.info('Vector cache warmed successfully');
  } catch (error) {
    logger.warn('Vector cache warming failed:', error);
  }
}

async function warmAdviceVectors(
  items: TherapyAdvice[],
  cache: Map<string, Float32Array>,
  max = 300
) {
  logger.info(`Warming vector cache for ${Math.min(max, items.length)} items...`);
  const subset = items.slice(0, max);
  let successCount = 0;
  
  for (const it of subset) {
    const text =
      it.advice ||
      [...(it.contexts || []), ...(it.attachmentStyles || [])]
        .filter(Boolean)
        .join(' ');
    try {
      const v = await spacyClient.embed(text);
      cache.set(it.id, new Float32Array(v));
      successCount++;
    } catch (error) {
      // best-effort; skip on failure
      logger.debug(`Failed to embed vector for advice ${it.id}:`, error);
    }
  }
  
  logger.info(`Vector cache warmed: ${successCount}/${subset.length} vectors cached`);
}