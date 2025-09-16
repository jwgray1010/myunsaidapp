// api/v1/communicator/export.ts
/**
 * GET /api/v1/communicator/export - Export user profile data
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../_lib/wrappers';
import { success } from '../../_lib/http';
import { CommunicatorProfile } from '../../_lib/services/communicatorProfile';
import { logger } from '../../_lib/logger';
import { ensureBoot } from '../../_lib/bootstrap';

const bootPromise = ensureBoot();

// -------------------- Helper Functions --------------------
function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string ||
         req.query.userId as string ||
         'anonymous';
}

// -------------------- Route Handler --------------------

// GET /export - Export user profile data
async function exportProfile(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    const attachmentEstimate = profile.getAttachmentEstimate();

    logger.info('Profile exported', { userId });

    return success(res, {
      userId,
      exportData: {
        attachmentEstimate,
        exportTimestamp: new Date().toISOString(),
        version: '2.0.0'
      },
      format: 'json'
    });
  } catch (error) {
    logger.error('Profile export failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['GET'], exportProfile))));