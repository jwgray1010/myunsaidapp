// api/v1/communicator/observe.ts
/**
 * POST /api/v1/communicator/observe - Record communication observation
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../_lib/wrappers';
import { success } from '../../_lib/http';
import { CommunicatorProfile } from '../../_lib/services/communicatorProfile';
import { normalizeScores } from '../../_lib/utils/priors';
import { toneAnalysisService } from '../../_lib/services/toneAnalysis';
import { logger } from '../../_lib/logger';
import { metrics } from '../../_lib/metrics';
import { z } from 'zod';
import { ensureBoot } from '../../_lib/bootstrap';

const bootPromise = ensureBoot();

// -------------------- Validation Schema --------------------
const observeSchema = z.object({
  text: z.string().min(1).max(2000),
  meta: z.record(z.any()).optional(),
  personalityProfile: z.object({
    attachmentStyle: z.string(),
    communicationStyle: z.string(),
    personalityType: z.string(),
    emotionalState: z.string(),
    emotionalBucket: z.string(),
    personalityScores: z.record(z.number()).optional(),
    communicationPreferences: z.record(z.any()).optional(),
    isComplete: z.boolean(),
  }).optional(),
});

// -------------------- Helper Functions --------------------
function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string ||
         req.query.userId as string ||
         'anonymous';
}

// -------------------- Route Handler --------------------

// POST /observe - Record communication observation
async function observe(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);
  const validation = observeSchema.safeParse(req.body);

  if (!validation.success) {
    res.status(400).json({
      error: 'Validation failed',
      details: validation.error.errors
    });
    return;
  }

  const { text, meta } = validation.data;

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    // Seed local prior if provided and not already present
    // @ts-ignore access raw internal structure for prototype stage
    const internal: any = (profile as any).data;
    if (!internal.localPrior && req.body?.personalityProfile?.personalityScores) {
      const raw = req.body.personalityProfile.personalityScores as Record<string, number>;
      const priorNorm = normalizeScores({
        anxious: raw.anxiety_score ?? raw.anxious ?? 0,
        avoidant: raw.avoidance_score ?? raw.avoidant ?? 0,
        disorganized: raw.disorganized ?? 0,
        secure: raw.secure ?? raw.secure_score ?? 0,
      });
      internal.localPrior = {
        scores: priorNorm,
        weight: 1.0,
        seededAt: new Date().toISOString(),
        sourceVersion: req.body?.personalityProfile?.assessmentVersion || 'modern_v1.0',
      };
      const topEntry = (Object.entries(priorNorm) as Array<[string, number]>).sort((a,b)=>b[1]-a[1])[0];
      logger.info('Local prior seeded', { userId, top: topEntry[0] });
    }

    // Analyze the communication
    const toneResult = await toneAnalysisService.analyzeAdvancedTone(text, {
      context: meta?.context || 'general',
      isNewUser: false // For observations, analyze fully to build profile
    });

    // Record the observation
    profile.addCommunication(text, meta?.context || 'general', toneResult.primary_tone);

    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;

    metrics.trackUserAction('observe', userId, true);

    logger.info('Communication observed', {
      userId,
      textLength: text.length,
      tone: toneResult.primary_tone,
      attachment: attachmentEstimate.primary,
      isNewUser
    });

    return success(res, {
      userId,
      observation: {
        text,
        analysis: toneResult,
        context: meta?.context || 'general',
        timestamp: new Date().toISOString()
      },
      attachmentEstimate,
      isNewUser,
      message: isNewUser ? 'Thanks for your input! We\'re learning about your communication style.' : null,
      updated: true
    });
  } catch (error) {
    logger.error('Observation failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['POST'], observe))));