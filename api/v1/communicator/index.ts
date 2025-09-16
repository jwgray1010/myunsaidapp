// api/v1/communicator/index.ts
/**
 * GET /api/v1/communicator - Get user's communicator profile
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../_lib/wrappers';
import { success } from '../../_lib/http';
import { CommunicatorProfile } from '../../_lib/services/communicatorProfile';
import { normalizeScores, defaultPriorWeight } from '../../_lib/utils/priors';
import { dataLoader } from '../../_lib/services/dataLoader';
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

// GET /profile - Get user's communicator profile
async function getProfile(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    const attachmentEstimate = profile.getAttachmentEstimate();
    // Determine if user is new (e.g., based on data availability)
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;

    // Build optional breakdown (non-breaking)
    // @ts-ignore accessing potential localPrior injected elsewhere
    const localPrior = (profile as any).data?.localPrior;
    // @ts-ignore server signals map
    const rawSignals = (profile as any).data?.learningSignals || {};
    const daysObserved = Number(rawSignals.daysObserved || 0);
    const attachmentLearning = (await dataLoader.getAttachmentLearning?.()) || dataLoader.getAttachmentLearning();
    const learningDays = attachmentLearning?.learningDays || 7;
    const serverNorm = normalizeScores({
      anxious: Number(rawSignals.anxious)||0,
      avoidant: Number(rawSignals.avoidant)||0,
      disorganized: Number(rawSignals.disorganized)||0,
      secure: Number(rawSignals.secure)||0,
    });
    const priorWeightEffective = localPrior ? defaultPriorWeight(daysObserved, learningDays) : 0;

    logger.info('Profile retrieved', {
      userId,
      attachment: attachmentEstimate.primary,
      isNewUser
    });

    return success(res, {
      userId,
      attachmentEstimate,
      isNewUser,
      metadata: {
        version: '2.0.0-enhanced',
        lastUpdated: new Date().toISOString(),
        status: isNewUser ? 'learning' : 'active'
      },
      breakdown: {
        prior: localPrior?.scores || null,
        priorWeightEffective,
        serverSignals: serverNorm,
      }
    });
  } catch (error) {
    logger.error('Profile retrieval failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['GET'], getProfile))));