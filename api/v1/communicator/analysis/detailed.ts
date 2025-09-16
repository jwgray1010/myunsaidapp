// api/v1/communicator/analysis/detailed.ts
/**
 * POST /api/v1/communicator/analysis/detailed - Enhanced detailed analysis
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging } from '../../../_lib/wrappers';
import { success } from '../../../_lib/http';
import { CommunicatorProfile } from '../../../_lib/services/communicatorProfile';
import { normalizeScores } from '../../../_lib/utils/priors';
import { toneAnalysisService } from '../../../_lib/services/toneAnalysis';
import { suggestionsService } from '../../../_lib/services/suggestions';
import { spacyClient } from '../../../_lib/services/spacyClient';
import { logger } from '../../../_lib/logger';
import { metrics } from '../../../_lib/metrics';
import { z } from 'zod';
import { ensureBoot } from '../../../_lib/bootstrap';

const bootPromise = ensureBoot();

// -------------------- Validation Schema --------------------
const detailedAnalysisSchema = z.object({
  text: z.string().min(1).max(2000),
  context: z.string().optional(),
  includePatterns: z.boolean().optional(),
  includeSuggestions: z.boolean().optional(),
});

// -------------------- Helper Functions --------------------
function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string ||
         req.query.userId as string ||
         'anonymous';
}

// -------------------- Route Handler --------------------

// POST /analysis/detailed - Enhanced detailed analysis
async function detailedAnalysis(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);
  const validation = detailedAnalysisSchema.safeParse(req.body);

  if (!validation.success) {
    res.status(400).json({
      error: 'Validation failed',
      details: validation.error.errors
    });
    return;
  }

  const { text, context = 'general', includePatterns = true, includeSuggestions = true } = validation.data;

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    // Seed local prior if provided and not already present
    // @ts-ignore internal access
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

    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;

    // Run enhanced analysis
    const [toneResult, suggestionResult, spacyResult] = await Promise.all([
      toneAnalysisService.analyzeAdvancedTone(text, {
        context,
        attachmentStyle: attachmentEstimate.primary || undefined,
        includeAttachmentInsights: true,
        deepAnalysis: true,
        isNewUser
      }),
      includeSuggestions ? suggestionsService.generateAdvancedSuggestions(text, context, {
        id: userId,
        attachment: attachmentEstimate.primary,
        secondary: attachmentEstimate.secondary,
        windowComplete: attachmentEstimate.windowComplete
      }, {
        attachmentStyle: attachmentEstimate.primary || undefined,
        isNewUser
      }) : null,
      includePatterns ? spacyClient.analyze(text) : null
    ]);

    metrics.trackServiceUsage('enhanced_analysis', 'detailed', Date.now());

    logger.info('Detailed analysis completed', {
      userId,
      textLength: text.length,
      tone: toneResult.primary_tone,
      suggestionCount: suggestionResult?.suggestions.length || 0,
      isNewUser
    });

    return success(res, {
      userId,
      text,
      context,
      isNewUser,
      analysis: {
        tone: toneResult,
        suggestions: suggestionResult,
        linguistic: spacyResult,
        attachment: attachmentEstimate
      },
      metadata: {
        analysisType: 'enhanced',
        timestamp: new Date().toISOString(),
        version: '2.0.0',
        status: isNewUser ? 'learning' : 'active'
      }
    });
  } catch (error) {
    logger.error('Detailed analysis failed:', error);
    throw error;
  }
}

export default withErrorHandling(withLogging(withCors(withMethods(['POST'], detailedAnalysis))));