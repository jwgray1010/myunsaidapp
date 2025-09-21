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

// Idempotency cache for duplicate request prevention
const idempotencyCache = new Map<string, { result: any; timestamp: number }>();

// Cleanup cache entries older than 10s every 30s  
setInterval(() => {
  const cutoff = Date.now() - 10000;
  for (const [key, entry] of idempotencyCache.entries()) {
    if (entry.timestamp < cutoff) {
      idempotencyCache.delete(key);
    }
  }
}, 30000);

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

  // === FULL-TEXT MODE HANDLING ===
  const mode = data.mode || 'full'; // 'full' for document-level, 'legacy' for sentence-based
  const isFullMode = mode === 'full';
  
  if (isFullMode) {
    // Document-level analysis requires doc_seq and text_hash
    const docSeq = data.doc_seq;
    const providedHash = data.text_hash;
    
    if (typeof docSeq !== 'number' || typeof providedHash !== 'string') {
      logger.warn('Full mode requires doc_seq and text_hash', { userId, mode, docSeq, providedHash });
      throw new Error('Full mode requires doc_seq (number) and text_hash (string)');
    }
    
    // Validate text_hash matches actual text
    const actualHash = require('crypto').createHash('sha256').update(data.text).digest('hex');
    if (providedHash !== actualHash) {
      logger.warn('Text hash mismatch in full mode', { 
        userId, 
        docSeq, 
        providedHash: providedHash.slice(0, 8), 
        actualHash: actualHash.slice(0, 8) 
      });
      throw new Error(`Text hash mismatch - expected ${actualHash.slice(0, 8)}, got ${providedHash.slice(0, 8)}`);
    }
    
    logger.info('Full-text document analysis mode activated', { userId, docSeq, textLength: data.text.length, hash: actualHash.slice(0, 8) });
  }

  // === SERVER-SIDE FIXES: Idempotency & Short-Text Gating ===
  
  // 1. Idempotency cache (prevent duplicate analysis)
  let idempotencyKey: string;
  if (isFullMode) {
    // For full mode, use doc_seq + text_hash
    idempotencyKey = `${userId}:full:${data.doc_seq}:${data.text_hash.slice(0, 8)}`;
  } else {
    // For legacy mode, use client_seq + text_hash  
    const textHash = Buffer.from(data.text).toString('base64').slice(0, 16);
    idempotencyKey = `${userId}:${clientSeq}:${textHash}`;
  }
  
  // Simple in-memory cache with 2s TTL
  const now = Date.now();
  const cacheEntry = idempotencyCache.get(idempotencyKey);
  if (cacheEntry && (now - cacheEntry.timestamp) < 2000) {
    logger.info('Returning cached result (idempotency)', { 
      userId, 
      mode, 
      docSeq: isFullMode ? data.doc_seq : undefined,
      clientSeq: !isFullMode ? clientSeq : undefined 
    });
    return success(res, cacheEntry.result);
  }
  
  // 2. Short-text gate (skip for full mode - let it be analyzed as document)
  const trimmed = data.text.trim();
  const wordCount = trimmed.split(/\s+/).filter((w: string) => w.length > 0).length;
  const isShort = trimmed.length < 4 || wordCount < 2;
  
  if (isShort && !isFullMode) {
    const insufficientResult = {
      ok: true,
      userId,
      text: data.text,
      ui_tone: "insufficient" as const,
      reason: "too_short",
      ui_distribution: { clear: 0, caution: 0, alert: 0 },
      buckets: { clear: 0, caution: 0, alert: 0 },
      confidence: 0,
      client_seq: clientSeq,
      analysis: {
        primary_tone: "insufficient",
        emotions: {},
        intensity: 0,
        sentiment_score: 0
      },
      metadata: {
        processingTimeMs: Date.now() - startTime,
        textLength: trimmed.length,
        wordCount,
        gated: "too_short"
      }
    };
    
    // Cache the insufficient result  
    idempotencyCache.set(idempotencyKey, { result: insufficientResult, timestamp: now });
    logger.info('Short text gated', { userId, textLength: trimmed.length, wordCount });
    return success(res, insufficientResult);
  }
  
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
    
    // Perform analysis using appropriate method based on mode
    let result;
    if (isFullMode) {
      // Document-level analysis with safety gates
      result = await toneAnalysisService.analyzeFull(data.text, {
        context: data.context,
        docSeq: data.doc_seq,
        preventSnapBacks: true
      });
    } else {
      // Legacy sentence-based analysis
      result = await toneAnalysisService.analyzeAdvancedTone(data.text, {
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
    }
    
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
    const attachmentStyle = data.attachmentStyle || "secure";
    const inputText = data.text || "";
    
    // === FIX: ELIMINATE DUPLICATE ANALYSIS ===
    // Extract buckets from the analysis result if available, otherwise use simple mapping
    let uiBuckets: Record<Bucket, number>;
    
    if ((result as any).buckets) {
      // Use buckets from analysis result if available
      uiBuckets = (result as any).buckets;
      logger.info('Using buckets from analysis result', { buckets: uiBuckets });
    } else {
      // Fallback: simple mapping based on tone
      const tone = result.primary_tone.toLowerCase();
      if (tone.includes('alert') || tone.includes('angry') || tone.includes('hostile')) {
        uiBuckets = { clear: 0.2, caution: 0.3, alert: 0.5 };
      } else if (tone.includes('caution') || tone.includes('concerned') || tone.includes('tense')) {
        uiBuckets = { clear: 0.3, caution: 0.5, alert: 0.2 };
      } else {
        uiBuckets = { clear: 0.6, caution: 0.3, alert: 0.1 };
      }
      logger.info('Using fallback bucket mapping', { tone, buckets: uiBuckets });
    }
    
    // === 3. CONFIDENCE & META-CLASSIFIER GATING ===
    const confidence = result.confidence || 0;
    const pAlert = metaClassifier.pAlert || 0;
    const pCaution = metaClassifier.pCaution || 0;
    const lowConf = confidence < 0.35;
    const metaHot = pAlert >= 0.5 || pCaution >= 0.5;
    
    // === 4. PROFANITY PREFIX GATING ===
    const profanityAnalysis = (result as any).profanityAnalysis || { hasProfanity: false, hasProfanityPrefix: false };
    const hasProfanityPrefix = profanityAnalysis.hasProfanityPrefix || false;
    const tokens = trimmed.split(/\s+/).length;
    const applyPrefixGate = !isFullMode && hasProfanityPrefix && tokens < 2;
    
    if (lowConf || metaHot || applyPrefixGate) {
      logger.info('Applying confidence/meta/profanity gating', { 
        confidence, 
        pAlert, 
        pCaution, 
        lowConf, 
        metaHot,
        hasProfanityPrefix,
        applyPrefixGate,
        tokens,
        originalBuckets: uiBuckets 
      });
      
      // Force caution blend - raise caution/alert floor, lower clear ceiling
      if (applyPrefixGate) {
        // Stronger penalty for profanity prefixes in short text
        uiBuckets = {
          clear: Math.min(uiBuckets.clear, 0.2),      // cap clear at 20%
          caution: Math.max(uiBuckets.caution, 0.5), // floor caution at 50%
          alert: Math.max(uiBuckets.alert, 0.25)     // floor alert at 25%
        };
      } else {
        // Standard confidence/meta gating
        uiBuckets = {
          clear: Math.min(uiBuckets.clear, 0.4),      // cap clear at 40%
          caution: Math.max(uiBuckets.caution, 0.35), // floor caution at 35%
          alert: Math.max(uiBuckets.alert, 0.15)      // floor alert at 15%
        };
      }
      
      logger.info('Post-gating buckets', { buckets: uiBuckets });
    }
    
    logger.info('Json bucket mapping applied', { 
      tone: result.primary_tone, 
      context: primaryContext,
      intensity: intensity,
      metaClassifier: metaClassifier,
      contextSeverity: contextSeverity,
      buckets: uiBuckets,
      guardrailsApplied: true,
      confidenceGating: lowConf || metaHot
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
      ui_tone
    });
    
    // Extract categories from tone analysis result
    const categories = (result as any).categories || [];
    
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
      // Categories from tone pattern matching for suggestions service
      categories,
      // Full-mode specific fields
      ...(isFullMode && {
        mode: 'full',
        doc_seq: data.doc_seq,
        text_hash: data.text_hash,
        doc_tone: ui_tone,  // Document-level tone for UI consistency
      }),
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
        model_version: isFullMode ? 'v1.0.0-full-text' : 'v1.0.0-advanced',
        // Feature noticings now handled on device for mass user scalability
        feature_noticings: [],
        ...(isFullMode && {
          analysis_type: 'document_level',
          safety_gates_applied: lowConf || metaHot || (hasProfanityPrefix && tokens < 2)
        })
      }
    };
    
    // Cache the successful result for idempotency
    idempotencyCache.set(idempotencyKey, { result: response, timestamp: now });
    
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