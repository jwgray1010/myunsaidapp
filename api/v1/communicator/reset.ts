// api/v1/communicator/reset.ts
/**
 * POST /api/v1/communicator/reset - Reset user profile
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../_lib/wrappers';
import { success } from '../../_lib/http';
import { CommunicatorProfile } from '../../_lib/services/communicatorProfile';
import { logger } from '../../_lib/logger';
import { metrics } from '../../_lib/metrics';
import { ensureBoot } from '../../_lib/bootstrap';

const bootPromise = ensureBoot();

// -------------------- Helper Functions --------------------
function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string ||
         req.query.userId as string ||
         'anonymous';
}

// -------------------- Route Handler --------------------

// POST /reset - Reset user profile
async function resetProfile(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    // For now, just create a new profile instance
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    metrics.trackUserAction('reset_profile', userId, true);

    logger.info('Profile reset', { userId });

    return success(res, {
      userId,
      reset: true,
      timestamp: new Date().toISOString(),
      message: 'Profile successfully reset'
    });
  } catch (error) {
    logger.error('Profile reset failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['POST'], resetProfile))));