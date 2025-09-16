// api/v1/communicator/status.ts
/**
 * GET /api/v1/communicator/status - Get profile status and health
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../_lib/wrappers';
import { success } from '../../_lib/http';
import { CommunicatorProfile } from '../../_lib/services/communicatorProfile';
import { spacyClient } from '../../_lib/services/spacyClient';
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

// GET /status - Get profile status and health
async function getStatus(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    const attachmentEstimate = profile.getAttachmentEstimate();

    const status = {
      userId,
      isActive: true,
      profileHealth: {
        attachmentConfidence: attachmentEstimate.confidence,
        windowComplete: attachmentEstimate.windowComplete
      },
      services: {
        toneAnalysis: true,
        suggestions: true,
        spacyClient: await spacyClient.healthCheck(),
        dataLoader: true
      },
      version: '2.0.0-enhanced'
    };

    logger.info('Status retrieved', { userId, status: 'healthy' });

    return success(res, status);
  } catch (error) {
    logger.error('Status check failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['GET'], getStatus))));