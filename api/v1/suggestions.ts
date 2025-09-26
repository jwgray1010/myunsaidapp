// api/v1/suggestions.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withErrorHandling, withLogging, withResponseNormalization } from '../_lib/wrappers';
import { suggestionsRateLimit } from '../_lib/rateLimit';
import { suggestionResponseSchema } from '../_lib/schemas/suggestionRequest';
import { normalizeSuggestionResponse } from '../_lib/schemas/normalize';
import { suggestionsService } from '../_lib/services/suggestions';
import { dataLoader } from '../_lib/services/dataLoader';
import { adjustToneByAttachment, applyThresholdShift } from '../_lib/services/utils/attachmentToneAdjust';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { logger } from '../_lib/logger';
import { ensureBoot } from '../_lib/bootstrap';
import crypto from 'crypto';

const bootPromise = ensureBoot();

// ✅ LOCAL V1 CONTRACT VALIDATION - Define inline since schema exports missing
interface SuggestionInputV1 {
  text: string;
  text_sha256: string;
  client_seq: number;
  compose_id: string;
  toneAnalysis: {
    classification: string;
    confidence: number;
    ui_distribution: { clear: number; caution: number; alert: number };
    intensity?: number;
  };
  context: string;
  attachmentStyle: string;
  rich?: any;
  meta?: any;
}

// Local validation functions
function validateTextSHA256(text: string, expectedHash: string): boolean {
  const actualHash = crypto.createHash('sha256').update(text, 'utf8').digest('hex');
  return actualHash === expectedHash;
}

function generateTextSHA256(text: string): string {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function validateUIDistribution(distribution: { clear: number; caution: number; alert: number }): boolean {
  const sum = distribution.clear + distribution.caution + distribution.alert;
  return Math.abs(sum - 1.0) < 0.01; // Allow small floating point variance
}

function isValidSuggestionInputV1(body: any): { success: boolean; data?: SuggestionInputV1; error?: any } {
  if (!body || typeof body !== 'object') {
    return { success: false, error: { message: 'Request body must be an object' } };
  }
  
  // Essential required fields for core functionality
  const required = ['text', 'context', 'attachmentStyle'];
  const missing = required.filter(field => !(field in body));
  if (missing.length > 0) {
    return { success: false, error: { message: `Missing required fields: ${missing.join(', ')}` } };
  }

  // Generate missing optional fields with defaults
  const normalizedBody: SuggestionInputV1 = {
    ...body,
    text_sha256: body.text_sha256 || generateTextSHA256(body.text || ''),
    compose_id: body.compose_id || `compose-${Date.now()}-${Math.random().toString(36).slice(2, 11)}`,
    client_seq: Number.isFinite(body.client_seq) ? body.client_seq : 1,
    toneAnalysis: {
      classification: body.toneAnalysis?.classification ?? 'neutral',
      confidence: Number.isFinite(body.toneAnalysis?.confidence) ? body.toneAnalysis.confidence : 0.5,
      ui_distribution: body.toneAnalysis?.ui_distribution ?? { clear: 0.34, caution: 0.33, alert: 0.33 },
      intensity: Number.isFinite(body.toneAnalysis?.intensity) ? body.toneAnalysis.intensity : 0.5,
    },
  };
  
  return { success: true, data: normalizedBody };
}

// Request deduplication and ordering cache (in-memory for now)
interface RequestCacheEntry {
  userId: string;
  compose_id: string;
  client_seq: number;
  text_sha256: string;
  response: any;
  timestamp: number;
}

const requestCache = new Map<string, RequestCacheEntry>();
const MAX_CACHE_SIZE = 1000;
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

function cleanupCache() {
  const now = Date.now();
  for (const [key, entry] of requestCache.entries()) {
    if (now - entry.timestamp > CACHE_TTL_MS) {
      requestCache.delete(key);
    }
  }
  // If still too large, remove oldest entries
  if (requestCache.size > MAX_CACHE_SIZE) {
    const entries = Array.from(requestCache.entries())
      .sort((a, b) => a[1].timestamp - b[1].timestamp);
    const toRemove = entries.slice(0, requestCache.size - MAX_CACHE_SIZE);
    for (const [key] of toRemove) {
      requestCache.delete(key);
    }
  }
}

function getCacheKey(userId: string, compose_id: string, client_seq: number, text_sha256: string): string {
  return `${userId}:${compose_id}:${client_seq}:${text_sha256}`;
}

function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string || 'anonymous';
}

// Helper: Post-shift bucket normalization (no NaN/negatives)
function normalizeBuckets(b: any) {
  const clamp = (v: any) => Number.isFinite(v) ? Math.max(0, v) : 0;
  const c = { clear: clamp(b?.clear), caution: clamp(b?.caution), alert: clamp(b?.alert) };
  let sum = c.clear + c.caution + c.alert;
  if (sum <= 0) { c.clear = 1; c.caution = 0; c.alert = 0; sum = 1; }
  return { clear: c.clear/sum, caution: c.caution/sum, alert: c.alert/sum };
}

const handler = async (req: VercelRequest, res: VercelResponse) => {
  await bootPromise;
  const startTime = Date.now();
  const userId = getUserId(req);
  
  // STEP 1: Validate the canonical v1 contract
  const validation = isValidSuggestionInputV1(req.body);
  if (!validation.success) {
    logger.error('Invalid request format - missing required v1 contract fields', {
      userId,
      errors: validation.error,
      timestamp: new Date().toISOString()
    });
    
    res.status(400).json({
      success: false,
      error: 'Invalid request format. Required: text, context, attachmentStyle. Other fields are auto-filled if missing (compose_id, client_seq, text_sha256, toneAnalysis).',
      details: validation.error,
      contract_version: 'v1'
    });
    return;
  }
  
  const data: SuggestionInputV1 = validation.data!;
  
  // STEP 2: Validate text SHA256 matches content
  if (!validateTextSHA256(data.text, data.text_sha256)) {
    logger.error('Text SHA256 mismatch - security violation', {
      userId,
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      expected_length: data.text.length,
      timestamp: new Date().toISOString()
    });
    
    res.status(400).json({
      success: false,
      error: 'Text SHA256 mismatch. Provided hash does not match text content.',
      contract_version: 'v1'
    });
    return;
  }
  
  // STEP 3: Validate UI distribution sums correctly (defensive)
  if (!data.toneAnalysis?.ui_distribution || !validateUIDistribution(data.toneAnalysis.ui_distribution)) {
    // Be defensive: normalize instead of hard-failing
    data.toneAnalysis.ui_distribution = normalizeBuckets(data.toneAnalysis.ui_distribution || { clear: 0.34, caution: 0.33, alert: 0.33 });
    logger.warn('Invalid UI distribution normalized', {
      userId,
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      original_distribution: data.toneAnalysis?.ui_distribution,
      normalized_distribution: data.toneAnalysis.ui_distribution,
      timestamp: new Date().toISOString()
    });
  }
  
  // STEP 4: Check for duplicate requests (idempotency)
  cleanupCache(); // Clean up old entries
  const cacheKey = getCacheKey(userId, data.compose_id, data.client_seq, data.text_sha256);
  const existing = requestCache.get(cacheKey);
  
  if (existing) {
    logger.info('Returning cached response for duplicate request', {
      userId,
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      cache_age_ms: Date.now() - existing.timestamp
    });
    
    res.status(208).json({
      ...existing.response,
      cached: true,
      cache_hit_timestamp: new Date().toISOString()
    });
    return;
  }
  
  // STEP 5: Check client_seq ordering (prevent out-of-order requests)
  // Find the highest client_seq for this user + compose_id combination
  let maxSeqForCompose = -1;
  for (const entry of requestCache.values()) {
    if (entry.userId === userId && entry.compose_id === data.compose_id && entry.client_seq > maxSeqForCompose) {
      maxSeqForCompose = entry.client_seq;
    }
  }
  
  if (data.client_seq <= maxSeqForCompose) {
    logger.error('Out-of-order request rejected', {
      userId,
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      max_seen_seq: maxSeqForCompose,
      timestamp: new Date().toISOString()
    });
    
    res.status(409).json({
      success: false,
      error: `Out-of-order request. client_seq ${data.client_seq} <= last seen ${maxSeqForCompose}`,
      max_seen_seq: maxSeqForCompose,
      contract_version: 'v1'
    });
    return;
  }
  
  logger.info('Processing canonical v1 suggestion request', { 
    userId,
    compose_id: data.compose_id,
    client_seq: data.client_seq,
    text_length: data.text.length,
    context: data.context,
    tone_classification: data.toneAnalysis.classification,
    attachment_style: data.attachmentStyle,
    has_rich_analysis: !!data.rich
  });
  
  try {
    // Initialize user profile
    const profile = new CommunicatorProfile({
      userId
    });
    await profile.init();
    
    // Get attachment estimate (use canonical contract override if provided)
    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;
    const finalAttachmentStyle = data.attachmentStyle === 'unknown' ? 
      (attachmentEstimate.primary || 'secure') : 
      data.attachmentStyle;
    
    // Extract tone analysis from canonical contract (no fallbacks needed)
    const toneResult = {
      classification: data.toneAnalysis.classification,
      confidence: data.toneAnalysis.confidence
    };
    
    // ✅ BUILD FULLTONEANALYSIS MIRRORING TONE.TS STRUCTURE
    // Consolidate analysis fields under analysis{...} subtree for consistency with tone.ts
    const fullToneAnalysis = {
      // Required ToneResponse fields
      ok: true,
      userId,
      tone: data.toneAnalysis.classification,      // for convenience
      confidence: data.toneAnalysis.confidence,
      
      // UI fields from canonical contract - these are authoritative from coordinator
      ui_tone: data.toneAnalysis.classification as 'clear' | 'caution' | 'alert' | 'neutral' | 'insufficient',
      ui_distribution: data.toneAnalysis.ui_distribution,
      
      // Optional top-level fields from tone.ts
      intensity: data.toneAnalysis.intensity ?? 0.5,
      categories: data.rich?.categories ?? [],
      timestamp: data.rich?.timestamp,
      attachmentEstimate: data.rich?.attachmentEstimate,
      isNewUser: data.rich?.isNewUser,
      
      // Keep raw_tone if coordinator included it in rich (optional)
      raw_tone: data.rich?.raw_tone,
      
      // ✅ ANALYSIS SUBTREE - mirrors tone.ts structure for downstream service consistency
      analysis: {
        primary_tone: data.toneAnalysis.classification, // aligns with tone.ts analysis.primary_tone semantics
        emotions: data.rich?.emotions ?? {},
        intensity: data.toneAnalysis.intensity ?? 0.5,
        sentiment_score: data.rich?.sentiment_score ?? 0,
        linguistic_features: data.rich?.linguistic_features ?? {},
        context_analysis: data.rich?.context_analysis ?? {},
        attachment_insights: data.rich?.attachment_insights ?? []
      },
      
      // Metadata with rich data preserved
      metadata: {
        ...(data.rich?.metadata ?? {}),
        model_version: 'v1.0.0-canonical',
        processingTimeMs: 0 // Will be updated at end
      },
      
      // Version field
      version: 'v1.0.0-canonical'
    };
    
    logger.info('Built fullToneAnalysis with tone.ts-compatible structure', { 
      tone: toneResult.classification,
      confidence: toneResult.confidence,
      intensity: fullToneAnalysis.intensity,
      ui_distribution: data.toneAnalysis.ui_distribution,
      has_analysis_emotions: Object.keys(fullToneAnalysis.analysis.emotions).length > 0,
      has_analysis_linguistic_features: Object.keys(fullToneAnalysis.analysis.linguistic_features).length > 0,
      has_analysis_context_analysis: Object.keys(fullToneAnalysis.analysis.context_analysis).length > 0,
      has_analysis_attachment_insights: fullToneAnalysis.analysis.attachment_insights.length > 0,
      source: 'canonical_v1_contract'
    });

    // Pass raw tone classification directly to suggestions service
    // The service will handle both UI tones (clear/caution/alert) and raw tones (assertive, etc.)
    const rawToneClassification = data.toneAnalysis.classification;
    const toneKeyNorm = rawToneClassification; // Keep original raw tone for therapy advice matching
    
    // Generate suggestions using the dedicated service with canonical tone analysis
    logger.info('About to call suggestionsService.generateAdvancedSuggestions', {
      textLength: data.text.length,
      context: data.context,
      userId,
      attachmentStyle: finalAttachmentStyle,
      tone_classification: data.toneAnalysis.classification,
      isNewUser
    });

    let suggestionAnalysis;
    try {
      // Generate suggestions with canonical contract data
      suggestionAnalysis = await suggestionsService.generateAdvancedSuggestions(
        data.text,
        data.context,
        {
          id: userId,
          attachment: finalAttachmentStyle,
          secondary: attachmentEstimate.secondary,
          windowComplete: attachmentEstimate.windowComplete
        },
        {
          maxSuggestions: 3,
          attachmentStyle: finalAttachmentStyle,
          relationshipStage: data.meta?.relationshipStage,
          conflictLevel: data.meta?.conflictLevel || 'low',
          isNewUser,
          fullToneAnalysis: fullToneAnalysis
        }
      );
      logger.info('suggestionsService.generateAdvancedSuggestions completed successfully');
    } catch (suggestionError) {
      logger.error('Error in suggestionsService.generateAdvancedSuggestions:', {
        error: suggestionError,
        message: suggestionError instanceof Error ? suggestionError.message : String(suggestionError),
        stack: suggestionError instanceof Error ? suggestionError.stack : undefined,
        name: suggestionError instanceof Error ? suggestionError.name : 'UnknownError',
        compose_id: data.compose_id,
        client_seq: data.client_seq
      });
      throw suggestionError;
    }
        // Session-based processing - no server-side storage for mass users
    
    // Make the noticings & matches visible for UX / analytics (simulated for session)
    if (suggestionAnalysis?.analysis?.flags) {
      suggestionAnalysis.analysis.flags.phraseEdgeHits = [
        ...(suggestionAnalysis.analysis.flags.phraseEdgeHits || [])
      ];
      (suggestionAnalysis as any).analysis.flags.featureNoticings = [];
    }

    // Session-only processing - no persistent dialogue state for mass users

    // 3) Use canonical context for history tracking
    const detectedContext = suggestionAnalysis.analysis?.context?.label || data.context;
    profile.addCommunication(data.text, detectedContext, toneKeyNorm);

    // ✅ USE CANONICAL UI DISTRIBUTION AS BASELINE - Do not mutate the original
    const baseBuckets = data.toneAnalysis.ui_distribution;

    // 5) Apply attachment adjustments and threshold shifts using canonical data
    // Create normalized copy without mutating original distribution
    const contextKey =
      data.context === 'conflict'   ? 'CTX_CONFLICT'  :
      data.context === 'planning'   ? 'CTX_PLANNING'  :
      data.context === 'boundary'   ? 'CTX_BOUNDARY'  :
      data.context === 'repair'     ? 'CTX_REPAIR'    : 'CTX_GENERAL';

    const intensityScore = data.toneAnalysis.intensity ?? 0.5;

    // Session-only tone bucket processing (no server-side feature hints for mass users)
    const baseBucketsWithFS = {
      clear: Math.max(0, baseBuckets.clear),
      caution: Math.max(0, baseBuckets.caution),
      alert: Math.max(0, baseBuckets.alert)
    };
    // Normalize base buckets
    const fsSum = baseBucketsWithFS.clear + baseBucketsWithFS.caution + baseBucketsWithFS.alert || 1;
    baseBucketsWithFS.clear /= fsSum;
    baseBucketsWithFS.caution /= fsSum;
    baseBucketsWithFS.alert /= fsSum;

    const adjustedBuckets = adjustToneByAttachment(
      { classification: toneResult.classification, confidence: toneResult.confidence },
      baseBucketsWithFS, // Use FS-adjusted buckets instead of original baseBuckets
      finalAttachmentStyle as any,
      contextKey,
      intensityScore,
      dataLoader.getAttachmentToneWeights()
    );

    const { primary: finalPrimary, distribution: rawBuckets } = applyThresholdShift(
      adjustedBuckets,
      finalAttachmentStyle as any,
      dataLoader.getAttachmentToneWeights()
    );

    const uiBuckets = normalizeBuckets(rawBuckets);

    const toneFromDist =
      uiBuckets.clear >= uiBuckets.caution && uiBuckets.clear >= uiBuckets.alert ? 'clear' :
      uiBuckets.alert >= uiBuckets.caution ? 'alert' : 'caution';
    const ui_tone = finalPrimary || toneFromDist;
    
    // Session-only processing - no persistent dialogue state for mass users
    
    const processingTime = Date.now() - startTime;
    
    logger.info('Advanced suggestions generated', { 
      userId,
      processingTimeMs: processingTime,
      pickedSize: suggestionAnalysis.suggestions.length,
      attachment: attachmentEstimate.primary,
      isNewUser
    });
    
    // Don't apply emergency fallback here - wait until after response mapping
    let picked = suggestionAnalysis.suggestions || [];
    
    // Cache the successful response
    const response = {
      text: data.text,
      original_text: data.text,
      context: data.context,
      ui_tone,
      ui_distribution: uiBuckets,
      
      // Canonical v1 correlation fields
      client_seq: data.client_seq,
      compose_id: data.compose_id,
      text_sha256: data.text_sha256,
      
      original_analysis: {
        tone: toneResult.classification as any, // Cast to match Bucket type  
        confidence: toneResult.confidence,
        
        // ✅ PRESERVE ORIGINAL vs ADJUSTED - use analysis subtree for consistency
        sentiment: fullToneAnalysis.analysis.sentiment_score,
        sentiment_score: fullToneAnalysis.analysis.sentiment_score,
        intensity: fullToneAnalysis.analysis.intensity,
        clarity_score: 0.5, // Default clarity (could be enhanced)
        empathy_score: 0.5, // Default empathy (could be enhanced)
        
        // ✅ ADD MISSING REQUIRED FIELDS for schema compatibility
        emotions: fullToneAnalysis.analysis.emotions || {},
        evidence: [], // Empty for now - could be populated with tone evidence
        communication_patterns: [], // Empty for now - could be populated from analysis
        metadata: fullToneAnalysis.metadata || {},
        complete_analysis_available: true,
        tone_analysis_source: 'coordinator_cache' as const,
        
        // Rich analysis data from canonical contract - use analysis subtree
        linguistic_features: fullToneAnalysis.analysis.linguistic_features,
        context_analysis: fullToneAnalysis.analysis.context_analysis,
        attachment_indicators: fullToneAnalysis.analysis.attachment_insights,
        attachmentInsights: fullToneAnalysis.analysis.attachment_insights,
        
        // ✅ PRESERVE ORIGINAL vs ADJUSTED DISTRIBUTIONS for observability
        ui_tone_original: data.toneAnalysis.classification,          // what tone.ts said
        ui_distribution_original: data.toneAnalysis.ui_distribution, // what tone.ts said
        ui_tone: ui_tone,                                           // adjusted for suggestions
        ui_distribution: uiBuckets,                                 // adjusted & normalized
        
        // ✅ ADD MISSING REQUIRED FIELDS for schema compatibility
        triggerTone: ui_tone,                                       // The final tone bucket selection (scalar for UI)
        triggerTones: [ui_tone, data.toneAnalysis.classification], // Multiple trigger tones (plural for analysis)
        trigger_tone_tags: [data.toneAnalysis.classification],     // Tags that triggered this tone
        
        // ✅ ADD REQUIRED LEARNING SIGNALS FIELD from suggestionAnalysis
        learning_signals: (suggestionAnalysis?.analysis as any)?.learningSignals || {
          patterns_detected: [],
          communication_buckets: [],
          attachment_hints: {},
          tone_adjustments: {},
          therapeutic_noticings: [],
          total_patterns_count: 0,
          buckets_detected_count: 0
        }
      },
      ok: true,
      success: true,
      version: 'v1.0.0-canonical',
      userId,
      attachmentEstimate,
      isNewUser,
      suggestions: picked.map((s: any, index: number) => ({
        id: s.id ?? `${index + 1}`,                              // stable ID if engine provided one
        text: s.text ?? s.advice,                                 // engine uses .advice internally
        type: s.type ?? 'advice',
        confidence: Math.max(0, Math.min(1, s.confidence ?? 0.55)),
        reason: s.reason ?? 'Therapeutic advice based on tone + context',
        category: s.category ?? (Array.isArray(s.categories) ? s.categories[0] : 'emotional'),
        categories: s.categories ?? (s.category ? [s.category] : ['emotional']),
        priority: s.priority ?? 1,
        context_specific: s.context_specific ?? true,
        attachment_informed: s.attachment_informed ?? true
      })),
      analysis_meta: suggestionAnalysis.analysis_meta,
      metadata: {
        processingTimeMs: processingTime,
        model_version: 'v1.0.0-advanced',
        attachment_informed: true,
        suggestion_count: picked.length,
        status: 'active', // Always active - learning happens in background
        feature_noticings: [], // Session-only processing for mass users
        
        // 🎯 ENHANCED: Track complete analysis data usage for optimization - use analysis subtree
        tone_analysis_source: (fullToneAnalysis ? 'coordinator_cache' : 'fresh_analysis') as 'coordinator_cache' | 'fresh_analysis' | 'override',
        complete_analysis_available: !!fullToneAnalysis,
        linguistic_features_used: !!(fullToneAnalysis?.analysis.linguistic_features && Object.keys(fullToneAnalysis.analysis.linguistic_features).length > 0),
        context_analysis_used: !!(fullToneAnalysis?.analysis.context_analysis && Object.keys(fullToneAnalysis.analysis.context_analysis).length > 0),
        attachment_insights_count: fullToneAnalysis?.analysis.attachment_insights?.length || 0
      }
    };
    
    // Emergency fallback for true system failures
    const responseHasSuggestions = Array.isArray(response.suggestions) && response.suggestions.length > 0;
    
    if (!responseHasSuggestions) {
      logger.error('CRITICAL: No suggestions returned - applying emergency fallback', { 
        userId,
        compose_id: data.compose_id,
        client_seq: data.client_seq,
        context: data.context,
        suggestionServiceLength: suggestionAnalysis?.suggestions?.length || 0,
        timestamp: new Date().toISOString()
      });
      
      response.suggestions = [{
        id: 'emergency-fallback-1',
        text: 'System temporarily unavailable. Please try again.',
        type: 'advice',
        confidence: 0.05,
        reason: 'Emergency system fallback - suggestions service failed',
        category: 'emotional',
        categories: ['emotional'],
        priority: 999,
        context_specific: false,
        attachment_informed: false
      }];
      response.metadata.suggestion_count = 1;
      response.metadata.status = 'emergency_fallback';
    }

    const b = response.ui_distribution;
    if (!b || [b.clear, b.caution, b.alert].some(v => !Number.isFinite(v))) {
      logger.warn('Invalid ui_distribution at boundary; normalizing');
      response.ui_distribution = normalizeBuckets(b || { clear: 1, caution: 0, alert: 0 });
    }
    
    // Cache successful response for idempotency
    requestCache.set(cacheKey, {
      userId,
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      text_sha256: data.text_sha256,
      response: response,
      timestamp: Date.now()
    });
    
    return response;
  } catch (error) {
    logger.error('Canonical v1 suggestions generation failed:', {
      error: error,
      message: error instanceof Error ? error.message : String(error),
      compose_id: data.compose_id,
      client_seq: data.client_seq,
      stack: error instanceof Error ? error.stack : undefined
    });
    throw error;
  }
};

const wrappedHandler = withErrorHandling(
  withLogging(
    withCors(
      withMethods(['POST'], 
        withResponseNormalization(normalizeSuggestionResponse, 
          // Direct handler - validation done inside handler function
          async (req: VercelRequest, res: VercelResponse) => {
            const response = await handler(req, res);
            
            // Additional validation logging for monitoring
            if (response) {
              const validation = suggestionResponseSchema.safeParse(response);
              if (!validation.success) {
                logger.error('Suggestions response schema validation failed', {
                  endpoint: '/api/v1/suggestions',
                  userId: req.headers['x-user-id'] || 'anonymous',
                  errors: validation.error.errors,
                  compose_id: req.body?.compose_id,
                  client_seq: req.body?.client_seq,
                  timestamp: new Date().toISOString()
                });
              } else {
                logger.debug('Suggestions response validation passed', {
                  userId: req.headers['x-user-id'] || 'anonymous',
                  compose_id: req.body?.compose_id,
                  suggestions_count: validation.data.suggestions?.length || 0
                });
              }
            }
            
            return response;
          }
        )
      )
    )
  )
);

export default (req: VercelRequest, res: VercelResponse) => {
  // Add security headers
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.setHeader('Surrogate-Control', 'no-store');
  
  return suggestionsRateLimit(req, res, () => {
    return wrappedHandler(req, res);
  });
};

// Pin to iad1 region for reduced latency
export const config = { regions: ['iad1'] };