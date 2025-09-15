// api/v1/tone.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging } from '../_lib/wrappers';
import { toneAnalysisRateLimit } from '../_lib/rateLimit';
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

type Bucket = 'clear'|'caution'|'alert';
function pickUiTone(b: Record<Bucket, number>): Bucket | 'neutral' {
  const vals = [b.clear ?? 0, b.caution ?? 0, b.alert ?? 0].sort((x,y)=>y-x);
  const top = vals[0], mid = vals[1], low = vals[2];
  // neutral only if all three are within 0.05
  return (Math.abs(top - mid) <= 0.05 && Math.abs(top - low) <= 0.05)
    ? 'neutral'
    : (b.alert >= b.caution && b.alert >= b.clear) ? 'alert'
    : (b.caution >= b.clear ? 'caution' : 'clear');
}

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
    
    // Copilot: Final pill color must be 'alert' | 'caution' | 'clear' | 'neutral'.
    // - Never set from raw labels like "angry"; labels only influence ui_distribution.
    // - Use pickUiTone(ui_distribution) which returns 'neutral' only if all three buckets are within 0.05.
    // - Always include { ui_tone, ui_distribution, buckets } in the response.
    
    // Map classifier → starting buckets (hint only; NOT the decider)
    const baseMap = mapToneToBuckets(
      { classification: result.primary_tone, confidence: result.confidence },
      'secure',
      data.context || 'general'
    );
    let uiBuckets = baseMap?.buckets || { clear: 1/3, caution: 1/3, alert: 1/3 };

    // Optional nudges from analysis context severity if present
    const sev = (result as any).contextSeverity || { clear: 0, caution: 0, alert: 0 };
    uiBuckets = {
      clear: Math.max(0, (uiBuckets.clear ?? 0) + (sev.clear || 0)),
      caution: Math.max(0, (uiBuckets.caution ?? 0) + (sev.caution || 0)),
      alert: Math.max(0, (uiBuckets.alert ?? 0) + (sev.alert || 0)),
    };
    // Normalize
    {
      const s = uiBuckets.clear + uiBuckets.caution + uiBuckets.alert || 1;
      uiBuckets.clear /= s; uiBuckets.caution /= s; uiBuckets.alert /= s;
    }

    // Final pill color via 3-way tie rule (neutral only when all three within .05)
    const ui_tone = pickUiTone(uiBuckets);

    const processingTime = Date.now() - startTime;    logger.info('Advanced tone analysis completed', { 
      processingTime,
      tone: result.primary_tone,
      confidence: result.confidence,
      userId,
      ui_tone,
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
      buckets: uiBuckets,            // legacy alias for old clients
      version: '1.0.0',
      timestamp: new Date().toISOString(),
      context: data.context || 'general',
      intensity: result.intensity,   // helps clients smooth if they want
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

const wrappedHandler = withErrorHandling(
  withLogging(
    withCors(
      withMethods(['POST'], 
        withValidation(toneRequestSchema, handler)
      )
    )
  )
);

export default (req: VercelRequest, res: VercelResponse) => {
  return toneAnalysisRateLimit(req, res, () => {
    return wrappedHandler(req, res);
  });
};