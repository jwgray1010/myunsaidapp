// api/_lib/bootstrap.ts
import { dataLoader } from './services/dataLoader';
import { initAdviceSearch } from './services/adviceIndex';
import { logger } from './logger';

let ready: Promise<void> | null = null;

/**
 * Ensure the backend “foundation” is initialized exactly once per process.
 * - Loads data cache
 * - Builds advice search index
 * If an initialization attempt fails, the guard resets so the next call can retry.
 */
export function ensureBoot(): Promise<void> {
  if (ready) return ready;

  const start = Date.now();

  ready = (async () => {
    logger.info('Bootstrapping services…');
    await dataLoader.initialize();     // no-op if already initialized
    await initAdviceSearch();          // builds BM25 & warms vectors (best-effort inside)
    logger.info(`Bootstrap complete in ${Date.now() - start}ms`);
  })()
    .catch((err) => {
      // Log and reset so a later call can retry (avoids “stuck rejected promise”)
      logger.error('Bootstrap failed:', err);
      ready = null;
      throw err;
    });

  return ready;
}

/** Optional helper for health checks / metrics endpoints. */
export function isBooted(): boolean {
  // We consider booted only if we have a settled, fulfilled promise.
  // There's no direct way to check settled state; treat presence of `ready`
  // as "in progress or done" to keep this lightweight.
  return !!ready;
}
