// api/_lib/bootstrap.ts
import { dataLoader } from './services/dataLoader';
import { initAdviceSearch } from './services/adviceIndex';
import { logger } from './logger';

export type BootStatus = 'idle' | 'booting' | 'ready' | 'error';

interface BootOptions {
  /** Fail the boot if it takes longer than this. Default: 20s */
  timeoutMs?: number;
  /** Force a fresh boot cycle even if a previous attempt failed. */
  force?: boolean;
  /** Skip warmups (useful in tests). Can also set BOOT_SKIP_WARMUPS=1 */
  skipWarmups?: boolean;
}

/**
 * Module-scoped single-flight state.
 * Multiple concurrent callers share the same Promise.
 */
let bootPromise: Promise<void> | null = null;
let status: BootStatus = 'idle';
let bootStartedAt: number | null = null;
let bootFinishedAt: number | null = null;
let lastError: Error | null = null;

/** Shallow status object for health/metrics endpoints. */
export function getBootInfo() {
  return {
    status,
    startedAt: bootStartedAt,
    finishedAt: bootFinishedAt,
    durationMs:
      bootStartedAt && bootFinishedAt ? bootFinishedAt - bootStartedAt : null,
    hadError: !!lastError,
    errorMessage: lastError?.message,
  };
}

/** True if a boot is in progress or already completed successfully. */
export function isBooted(): boolean {
  return status === 'ready' || status === 'booting';
}

/** Resets state so a future call to ensureBoot() can retry. */
function resetState() {
  bootPromise = null;
  status = 'idle';
  bootStartedAt = null;
  bootFinishedAt = null;
  lastError = null;
}

/** Promise that rejects after `ms`. */
function timeout(ms: number, label = 'bootstrap timeout'): Promise<never> {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(label)), ms);
  });
}

/**
 * Ensure the backend “foundation” is initialized exactly once per process.
 * - Loads the DataLoader cache
 * - Builds the advice search index
 * - Optional warmups (skippable via BOOT_SKIP_WARMUPS=1)
 *
 * Idempotent, single-flight, and guarded with a timeout.
 */
export function ensureBoot(opts: BootOptions = {}): Promise<void> {
  const {
    timeoutMs = Number(process.env.BOOT_TIMEOUT_MS ?? 20_000),
    force = false,
    skipWarmups = process.env.BOOT_SKIP_WARMUPS === '1',
  } = opts;

  // If we're already booting or ready, return the existing promise.
  if (bootPromise && !force) return bootPromise;

  // If previous attempt failed and caller doesn't force, expose the failure.
  if (status === 'error' && !force && bootPromise) return bootPromise;

  if (force) {
    logger.warn('Bootstrap: forcing re-initialization');
    resetState();
  }

  // Start a single-flight boot
  status = 'booting';
  bootStartedAt = Date.now();

  const startLog = () =>
    logger.info('Bootstrapping services…', {
      timeoutMs,
      skipWarmups,
      pid: process.pid,
    });

  const endOkLog = (ms: number) =>
    logger.info('Bootstrap complete', { durationMs: ms });

  const endErrLog = (ms: number, err: unknown) =>
    logger.error('Bootstrap failed', {
      durationMs: ms,
      error: (err as Error)?.message || String(err),
    });

  startLog();

  bootPromise = Promise.race([
    (async () => {
      // 1) Initialize data cache (no-op if already initialized)
      await dataLoader.initialize();

      // 2) Build advice index (BM25, vectors, etc.)
      await initAdviceSearch();

      // 3) Optional warmups or lightweight checks (safe-guarded)
      if (!skipWarmups) {
        try {
          // put any “nice-to-have” warms here (kept tiny to avoid cold start tax)
          // e.g., prefetch normalized advice count:
          const count = (dataLoader.getAllAdviceItems?.() || []).length;
          logger.debug('Bootstrap warmup: advice count', { count });
        } catch (e) {
          // never fail the boot due to warmups
          logger.warn('Bootstrap warmup skipped due to error', { err: (e as Error).message });
        }
      }

      return;
    })(),
    timeout(timeoutMs),
  ])
    .then(() => {
      status = 'ready';
      bootFinishedAt = Date.now();
      endOkLog(bootFinishedAt - (bootStartedAt ?? bootFinishedAt));
    })
    .catch((err) => {
      status = 'error';
      bootFinishedAt = Date.now();
      lastError = err as Error;
      endErrLog(bootFinishedAt - (bootStartedAt ?? bootFinishedAt), err);
      // keep the rejected promise so callers see the failure;
      // a future call with { force: true } can retry.
      throw err;
    });

  return bootPromise;
}

/**
 * Helper to guard a route handler with boot.
 * If boot fails, returns 503 with a compact body.
 *
 * Usage:
 *   export default withBoot(async (req, res) => { ... });
 */
export function withBoot<TArgs extends any[], TResult>(
  handler: (...args: TArgs) => Promise<TResult>,
  options?: BootOptions
) {
  return async (...args: TArgs): Promise<TResult> => {
    try {
      await ensureBoot(options);
      return await handler(...args);
    } catch (e) {
      // Re-throw for frameworks that have their own error handling,
      // or translate here to your HTTP util if desired.
      const msg = (e as Error)?.message || 'bootstrap failed';
      // We just log; actual response formatting should be done by the caller
      // (keeps this file framework-agnostic).
      logger.error('withBoot: handler blocked by bootstrap error', { msg });
      throw e;
    }
  };
}

/**
 * Fire-and-forget preboot for environments where the module is imported eagerly.
 * Safe to call; it won’t throw.
 */
export function preboot(options?: BootOptions) {
  ensureBoot(options).catch((e) =>
    logger.warn('Preboot encountered an error (will not crash process)', {
      error: (e as Error).message,
    })
  );
}
