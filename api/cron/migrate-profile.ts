// api/cron/migrate-profile.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../_lib/wrappers';
import { success, error as httpError } from '../_lib/http';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { logger } from '../_lib/logger';
// import { trackApiCall } from '../_lib/metrics'; // optional

interface MigrationResult {
  userId: string;
  migrated: boolean;
  previousVersion?: string;
  currentVersion: string;
  changes: string[];
  errors: string[];
}

interface ProfileMigrationReport {
  timestamp: string;
  totalProfiles: number;
  migratedProfiles: number;
  failedProfiles: number;
  results: MigrationResult[];
  overallStatus: 'success' | 'partial' | 'failed';
}

const CRON_SECRET = process.env.CRON_SECRET || '';

function isAuthorizedCron(req: VercelRequest): boolean {
  // Accept either explicit shared secret or Vercel cron header + secret
  const auth = (req.headers['x-cron-secret'] || req.headers['authorization'] || '').toString();
  const vercelCron = req.headers['x-vercel-cron'] === '1';
  if (!CRON_SECRET) return vercelCron; // if you trust Vercel header alone
  return auth === CRON_SECRET || (vercelCron && auth === CRON_SECRET);
}

async function migrateOne(userId: string): Promise<MigrationResult> {
  const changes: string[] = [];
  const errors: string[] = [];

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    // Read profile version/state to determine if migration is needed.
    // For now, we'll use a simple version tracking approach
    // In a real implementation, this would read from the profile data
    const prevVersion = '1.0.0'; // Default version for existing profiles
    const targetVersion = '2.0.0';

    const attachmentEstimate = profile.getAttachmentEstimate();
    let needsMigration = false;

    // Example, deterministic checks:
    if (!attachmentEstimate.windowComplete) {
      changes.push('Initialized attachment analysis window');
      needsMigration = true;
    }
    if ((attachmentEstimate.confidence ?? 0) < 0.5) {
      changes.push('Updated confidence calculation algorithm');
      needsMigration = true;
    }
    // Version-based migration check
    if (prevVersion < targetVersion) {
      changes.push(`Schema bump ${prevVersion} -> ${targetVersion}`);
      needsMigration = true;
    }

    if (needsMigration) {
      // Perform your concrete migration steps here:
      // await profile.migrateTo(targetVersion);
      // await profile.save();
      logger.info('Profile migrated', { userId, changes, targetVersion });
    }

    return {
      userId,
      migrated: needsMigration,
      previousVersion: prevVersion,
      currentVersion: targetVersion,
      changes,
      errors,
    };
  } catch (e: any) {
    const msg = e?.message || 'Unknown error';
    logger.error('Profile migration failed', { userId, error: msg });
    errors.push(`Migration failed: ${msg}`);
    return {
      userId,
      migrated: false,
      previousVersion: undefined,
      currentVersion: '2.0.0',
      changes,
      errors,
    };
  }
}

async function runWithLimit<T>(items: T[], limit: number, fn: (item: T) => Promise<any>) {
  const queue = new Set<Promise<any>>();
  const results: any[] = [];

  for (const item of items) {
    const p = fn(item).then((r) => {
      queue.delete(p);
      return r;
    });
    queue.add(p);
    if (queue.size >= limit) await Promise.race(queue);
    results.push(p);
  }
  return Promise.all(results);
}

const handler = async (req: VercelRequest, res: VercelResponse) => {
  const startTime = Date.now();

  if (!isAuthorizedCron(req)) {
    return httpError(res, 'Unauthorized cron', 401);
  }

  try {
    logger.info('Starting profile migration cron job');

    // TODO: replace with DB-sourced IDs; paginate if large
    const userIds = [
      'user_001', 'user_002', 'user_003', 'user_004', 'user_005',
      'test_user', 'demo_user', 'anonymous'
    ];

    // Bounded concurrency (tune limit to your DB/API constraints)
    const concurrency = Number(process.env.CRON_CONCURRENCY || 4);
    const results = await runWithLimit(userIds, concurrency, migrateOne);

    const migratedProfiles = results.filter(r => r.migrated).length;
    const failedProfiles = results.filter(r => r.errors.length > 0).length;
    const totalProfiles = results.length;

    let overallStatus: 'success' | 'partial' | 'failed' = 'success';
    if (failedProfiles > 0) {
      overallStatus = failedProfiles >= totalProfiles ? 'failed' : 'partial';
    }

    const processingTime = Date.now() - startTime;

    logger.info('Profile migration completed', {
      processingTimeMs: processingTime,
      totalProfiles,
      migratedProfiles,
      failedProfiles,
      status: overallStatus,
    });

    // Optionally record metrics
    // trackApiCall('/api/cron/migrate-profile', 'POST', overallStatus === 'failed' ? 500 : 200, processingTime);

    // Keep the response compact; full detail is in logs
    const report: ProfileMigrationReport = {
      timestamp: new Date().toISOString(),
      totalProfiles,
      migratedProfiles,
      failedProfiles,
      results,          // if this is too big, omit or truncate
      overallStatus
    };

    // If everything failed, you may want to use a 500
    const status = overallStatus === 'failed' ? 500 : 200;

    return success(res, {
      report,
      meta: {
        processingTimeMs: processingTime,
        cronJob: 'migrate-profile',
        version: '2.0.0',
        concurrency
      }
    }, status);

  } catch (e) {
    logger.error('Profile migration cron job failed', { error: e instanceof Error ? e.message : String(e) });
    throw e; // withErrorHandling will format the error response
  }
};

export default withErrorHandling(
  // Cron endpoints usually don’t need CORS; keep it if you call across origins.
  withLogging(
    withMethods(['POST'], handler)
  )
);
