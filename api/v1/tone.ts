// api/v1/tone.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging } from '../_lib/wrappers';
import { toneAnalysisRateLimit } from '../_lib/rateLimit';
import { success } from '../_lib/http';
import { toneRequestSchema } from '../_lib/schemas/toneRequest';
import { toneAnalysisService, mapToneToBuckets, getGeneralToneAnalysis, resetConversationMemory } from '../_lib/services/toneAnalysis';
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

  // Fix #6: Reset conversation memory if requested for testing isolation
  if (data.reset_memory === true) {
    resetConversationMemory(data.field_id);
  }

  const startTime = Date.now();
  const userId = getUserId(req);
  const clientSeq = (typeof data?.client_seq === 'number') ? data.client_seq
                   : (typeof data?.clientSeq === 'number') ? data.clientSeq
                   : undefined;
  
  logger.info('Processing advanced tone analysis request', { 
    userId,
    textLength: data.text.length,
    context: data.context
  });
  
  try {
    // Boot already done above; nothing to do here.

    // Initialize user profile
    const profile = new CommunicatorProfile({
      userId
    });
    await profile.init();
    
    // Get attachment estimate
    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;
    
    // Perform advanced analysis using the dedicated service
    const result = await toneAnalysisService.analyzeAdvancedTone(data.text, {
      context: data.context,
      attachmentStyle: attachmentEstimate.primary || undefined,
      // relationshipStage: data.meta?.relationshipStage,
      includeAttachmentInsights: true,
      deepAnalysis: true,
      isNewUser,
      userProfile: {
        id: userId,
        attachment: attachmentEstimate.primary,
        secondary: attachmentEstimate.secondary,
        windowComplete: attachmentEstimate.windowComplete
      }
    });
    
    // Add communication to profile history
    profile.addCommunication(data.text, data.context || 'general', result.primary_tone);
    
    // Copilot: Final pill color must be 'alert' | 'caution' | 'clear' | 'neutral'.
    // - Never set from raw labels like "angry"; labels only influence ui_distribution.
    // - Use pickUiTone(ui_distribution) which returns 'neutral' only if all three buckets are within 0.05.
    // - Always include { ui_tone, ui_distribution, buckets } in the response.
    
    // Use modern bucket mapping with context-aware guardrails (instead of hard-coded mapping)
    const primaryContext = (result as any).primaryContext || "general";
    const contextSeverity = (result as any).contextSeverity || { clear: 0, caution: 0, alert: 0 };
    const metaClassifier = (result as any).metaClassifier || { pAlert: 0, pCaution: 0 };
    const intensity = result.intensity || 0.5;
    const attachmentStyle = req.body.attachment_style || "secure";
    const inputText = req.body.text || "";
    // Removed bypass_overrides parameter - now defaults to bypass mode for production stability
    
    // Get sophisticated bucket mapping using modern approach (defaults to bypass mode)
    const advancedResult = await getGeneralToneAnalysis(inputText, attachmentStyle, primaryContext);
    
    // Use the advanced analysis buckets which include all guardrails and context-awareness
    let uiBuckets = advancedResult.buckets;
    
    logger.info('Json bucket mapping applied', { 
      tone: result.primary_tone, 
      context: primaryContext,
      intensity: intensity,
      metaClassifier: metaClassifier,
      contextSeverity: contextSeverity,
      buckets: uiBuckets,
      guardrailsApplied: true
    });
    
    // Normalize
    {
      const s = uiBuckets.clear + uiBuckets.caution + uiBuckets.alert || 1;
      uiBuckets.clear /= s; uiBuckets.caution /= s; uiBuckets.alert /= s;
    }

    // Final pill color via 3-way tie rule (neutral only when all three within .05)
    const ui_tone = pickUiTone(uiBuckets);
    
    // Session-only final tone tracking - no persistent state for mass user scalability

    const processingTime = Date.now() - startTime;
    
    logger.info('Advanced tone analysis completed', { 
      userId,
      processingTimeMs: processingTime,
      tone: result.primary_tone,
      confidence: result.confidence,
      ui_tone,
      // Feature spotting now handled on device - no server-side tracking
      featureSpotterMatches: 0,
      featureSpotterNoticings: 0
    });
    
    const response = {
      ok: true,
      userId,
      // echo original text if you want the response to be self-describing (optional)
      text: data.text,
      attachmentEstimate,
      isNewUser,
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
        processingTimeMs: processingTime,
        model_version: 'v1.0.0-advanced',
        // Feature noticings now handled on device for mass user scalability
        feature_noticings: []
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