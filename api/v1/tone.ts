// api/v1/tone.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging, withRateLimit } from '../_lib/wrappers';
import { success } from '../_lib/http';
import { toneRequestSchema } from '../_lib/schemas/toneRequest';
import { toneAnalysisService, mapToneToBuckets } from '../_lib/services/toneAnalysis';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { logger } from '../_lib/logger';
import { ensureBoot } from '../_lib/bootstrap';
import { spacyClient } from '../_lib/services/spacyClient';
import * as path from 'path';

// Pin the function near your users for lower RTT
export const config = { regions: ['iad1'] };

// Fire immediately at cold start
const bootPromise = (async () => {
  await ensureBoot();              // loads JSON into memory
  spacyClient.getServiceStatus();  // precompiles regex bundles, fills caches
})();

function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string || 'anonymous';
}

// helper: argmax over {clear,caution,alert}
function primaryBucket(buckets: Record<'clear'|'caution'|'alert', number>) {
  let best: keyof typeof buckets = 'clear', bestV = -1;
  (['clear','caution','alert'] as const).forEach(b => {
    const v = buckets[b] ?? 0;
    if (v > bestV) { best = b; bestV = v; }
  });
  return best;
}

const handler = async (req: VercelRequest, res: VercelResponse, data: any) => {
  await bootPromise; // ensures zero boot work on the request

  const startTime = Date.now();
  const userId = getUserId(req);
  const clientSeq = (typeof data?.client_seq === 'number') ? data.client_seq
                   : (typeof data?.clientSeq === 'number') ? data.clientSeq
                   : undefined;
  
  logger.info('Processing advanced tone analysis request', { 
    textLength: data.text.length,
    context: data.context,
    userId
  });
  
  try {
    // Boot already done above; nothing to do here.

    // Initialize user profile
    // const profile = new CommunicatorProfile({
    //   userId
    // });
    // await profile.init();
    
    // Get attachment estimate
    // const attachmentEstimate = profile.getAttachmentEstimate();
    // const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;
    
    // Perform advanced analysis using the dedicated service
    const result = await toneAnalysisService.analyzeAdvancedTone(data.text, {
      context: data.context,
      // attachmentStyle: attachmentEstimate.primary || undefined,
      // relationshipStage: data.meta?.relationshipStage,
      includeAttachmentInsights: true,
      deepAnalysis: true,
      // isNewUser,
      userProfile: {
        id: userId,
        // attachment: attachmentEstimate.primary,
        // secondary: attachmentEstimate.secondary,
        // windowComplete: attachmentEstimate.windowComplete
      }
    });
    
    // Add communication to profile history
    // profile.addCommunication(data.text, data.context, result.primary_tone);
    
    // Map classifier → UI buckets used by the keyboard pill
    const bucketed = mapToneToBuckets(
      { classification: result.primary_tone, confidence: result.confidence },
      // If you later surface attachment estimate, pass it; default to 'secure' for now.
      'secure',
      data.context || 'general'
    );
    const uiBuckets = bucketed?.buckets || { clear: 1/3, caution: 1/3, alert: 1/3 };
    const ui_tone = (Object.entries(uiBuckets).sort((a,b)=> (b[1] as number) - (a[1] as number))[0][0]) as 'clear'|'caution'|'alert';

    const processingTime = Date.now() - startTime;    logger.info('Advanced tone analysis completed', { 
      processingTime,
      tone: result.primary_tone,
      confidence: result.confidence,
      userId,
      // attachment: attachmentEstimate.primary,
      // isNewUser
    });
    
    const response = {
      ok: true,
      userId,
      // echo original text if you want the response to be self-describing (optional)
      text: data.text,
      // attachmentEstimate,
      // isNewUser,
      tone: result.primary_tone,
      confidence: result.confidence,
      // ➕ UI fields used by the iOS pill:
      ui_tone,
      ui_distribution: uiBuckets,
      // Echo client sequence for last-writer-wins on device (optional but helpful)
      client_seq: clientSeq,
      analysis: {
        primary_tone: result.primary_tone,     // Raw tone still available in analysis
        emotions: result.emotions,
        intensity: result.intensity,
        sentiment_score: result.sentiment_score,
        linguistic_features: result.linguistic_features,
        context_analysis: result.context_analysis,
        attachment_insights: result.attachment_insights,
      },
      metadata: {
        processing_time_ms: processingTime,
        model_version: 'v1.0.0-advanced',
        // attachment_informed: true,
        // status: isNewUser ? 'learning' : 'active'
      }
    };
    
    return success(res, response);
  } catch (error) {
    logger.error('Advanced tone analysis failed:', error);
    throw error;
  }
};

export default withErrorHandling(
  withLogging(
    withRateLimit()(
      withCors(
        withMethods(['POST'], 
          withValidation(toneRequestSchema, handler)
        )
      )
    )
  )
);