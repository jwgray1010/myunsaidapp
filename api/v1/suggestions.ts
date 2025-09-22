// api/v1/suggestions.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging, withResponseNormalization } from '../_lib/wrappers';
import { suggestionsRateLimit } from '../_lib/rateLimit';
import { suggestionRequestSchema, suggestionResponseSchema } from '../_lib/schemas/suggestionRequest';
import { normalizeSuggestionResponse } from '../_lib/schemas/normalize';
import { suggestionsService } from '../_lib/services/suggestions';
import { dataLoader } from '../_lib/services/dataLoader';
import { mapToneToBuckets, toneAnalysisService } from '../_lib/services/toneAnalysis';
import { adjustToneByAttachment, applyThresholdShift } from '../_lib/services/utils/attachmentToneAdjust';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { logger } from '../_lib/logger';
import { ensureBoot } from '../_lib/bootstrap';
import * as path from 'path';

const bootPromise = ensureBoot();

function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string || 'anonymous';
}

// Helper: ABSOLUTE EMERGENCY fallbacks - only for complete system failures
function ensureAtLeastOneSuggestion(items: any[], originalWasEmpty: boolean = false): any[] {
  // STRICT: Only provide fallback if the original suggestions service returned completely empty
  // AND this is explicitly marked as an emergency situation
  if (Array.isArray(items) && items.length > 0) return items;
  if (!originalWasEmpty) return []; // NEVER override if main service had any content
  
  // Log this critical situation
  console.error('CRITICAL FALLBACK: Main suggestions service completely failed to return content');
  
  // Absolute emergency fallbacks - normalized format matching main response structure
  const emergencyFallbacks = [
    {
      id: 'critical-emergency-1',
      text: 'System temporarily unavailable. Please try again in a moment.',
      advice: 'System temporarily unavailable. Please try again in a moment.', // Alias for backward compatibility
      type: 'advice',
      category: 'emotional', // ✅ Valid schema enum value
      categories: ['emotional'],
      confidence: 0.05, // Extremely low score
      priority: 999, // Lowest priority
      reason: 'Critical system fallback - main suggestions service failed',
      context_specific: false,
      attachment_informed: false,
      triggerTone: 'neutral', // Legacy field
      contexts: ['general'], // Legacy field
      ltrScore: 0.05, // Legacy field
    },
    {
      id: 'critical-emergency-2', 
      text: 'Unable to provide suggestions right now. Please check your connection.',
      advice: 'Unable to provide suggestions right now. Please check your connection.', // Alias for backward compatibility
      type: 'advice',
      category: 'emotional', // ✅ Valid schema enum value
      categories: ['emotional'],
      confidence: 0.05,
      priority: 999, // Lowest priority
      reason: 'Critical system fallback - main suggestions service failed',
      context_specific: false,
      attachment_informed: false,
      triggerTone: 'neutral', // Legacy field
      contexts: ['general'], // Legacy field
      ltrScore: 0.05, // Legacy field
    }
  ];
  
  // Return only ONE fallback to minimize interference
  const randomIndex = Math.floor(Math.random() * emergencyFallbacks.length);
  return [emergencyFallbacks[randomIndex]];
}

// Helper: Post-shift bucket normalization (no NaN/negatives)
function normalizeBuckets(b: any) {
  const clamp = (v: any) => Number.isFinite(v) ? Math.max(0, v) : 0;
  const c = { clear: clamp(b?.clear), caution: clamp(b?.caution), alert: clamp(b?.alert) };
  let sum = c.clear + c.caution + c.alert;
  if (sum <= 0) { c.clear = 1; c.caution = 0; c.alert = 0; sum = 1; }
  return { clear: c.clear/sum, caution: c.caution/sum, alert: c.alert/sum };
}

const handler = async (req: VercelRequest, res: VercelResponse, data: any) => {
  await bootPromise;
  const startTime = Date.now();
  const userId = getUserId(req);
  
  // ✅ Extract context from meta if not at top level (iOS coordinator pattern)
  const contextLabel = data.context || data.meta?.context || 'general';
  
  logger.info('Processing advanced suggestions request', { 
    userId,
    textLength: data.text.length,
    context: contextLabel,
    toneOverride: data.toneOverride,
    attachment: data.attachmentStyle,
    clientSeq: data.client_seq || data.clientSeq
  });
  
  try {
    // Initialize user profile
    const profile = new CommunicatorProfile({
      userId
    });
    await profile.init();
    
    // Get attachment estimate
    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;
    
    // FIRST: Get tone analysis - priority: toneAnalysis > toneOverride > run analysis
    logger.info('Determining tone for suggestions...', { 
      hasToneAnalysis: !!data.toneAnalysis, 
      hasToneOverride: !!data.toneOverride 
    });
    
    let toneResult: { classification: string; confidence: number } | null = null;
    let fullToneAnalysis: any = null;
    
    // Priority 1: Full tone analysis provided (best option - no duplicate computation)
    if (data.toneAnalysis) {
      fullToneAnalysis = {
        // Core tone fields that suggestions service expects
        tone: data.toneAnalysis.tone || data.toneAnalysis.classification || 'neutral',
        confidence: data.toneAnalysis.confidence || 0.5,
        
        // UI consistency fields
        ui_tone: data.toneAnalysis.ui_tone || 'clear',
        ui_distribution: data.toneAnalysis.ui_distribution || {},
        
        // Rich emotional and linguistic data for optimal therapy advice
        emotions: data.toneAnalysis.emotions || {},
        sentiment_score: data.toneAnalysis.sentiment_score,
        linguistic_features: data.toneAnalysis.linguistic_features || {},
        context_analysis: data.toneAnalysis.context_analysis || {},
        attachmentInsights: data.toneAnalysis.attachment_insights || [],
        
        // Metadata for comprehensive analysis
        metadata: data.toneAnalysis.metadata || { analysis_depth: data.toneAnalysis.intensity || 0.5 },
        
        // Additional fields for completeness
        intensity: data.toneAnalysis.intensity,
        evidence: data.toneAnalysis.evidence,
        suggestions: data.toneAnalysis.suggestions
      };
      
      toneResult = {
        classification: data.toneAnalysis.classification || data.toneAnalysis.tone || 'neutral',
        confidence: data.toneAnalysis.confidence || 0.5
      };
      
      logger.info('Using provided COMPLETE tone analysis from coordinator', { 
        tone: toneResult.classification, 
        ui_tone: fullToneAnalysis.ui_tone,
        confidence: toneResult.confidence,
        emotions: Object.keys(fullToneAnalysis.emotions || {}).length,
        hasLinguisticFeatures: !!fullToneAnalysis.linguistic_features,
        hasContextAnalysis: !!fullToneAnalysis.context_analysis,
        hasAttachmentInsights: Array.isArray(fullToneAnalysis.attachmentInsights) && fullToneAnalysis.attachmentInsights.length > 0,
        source: 'coordinator_cache',
        // 🎯 ENHANCED: Log what complete data we received for therapy advice
        dataCompleteness: {
          emotions: Object.keys(fullToneAnalysis.emotions || {}).join(','),
          sentimentScore: fullToneAnalysis.sentiment_score,
          linguisticFeatures: fullToneAnalysis.linguistic_features ? 'present' : 'missing',
          contextAnalysis: fullToneAnalysis.context_analysis ? 'present' : 'missing',
          attachmentInsights: fullToneAnalysis.attachmentInsights?.length || 0
        }
      });
    }
    // Priority 2: Simple tone override (for testing/manual control)
    else if (data.toneOverride) {
      toneResult = {
        classification: data.toneOverride, // This will be 'alert', 'caution', or 'clear'
        confidence: 0.9 // High confidence for manual override
      };
      logger.info('Using tone override from request', toneResult);
    } 
    // Priority 3: Run tone analysis (fallback when no tone data provided)
    else {
      // Run advanced tone analysis directly using the service for full meta-classifier benefits
      try {
        const result = await toneAnalysisService.analyzeAdvancedTone(data.text, {
          context: contextLabel, // Use extracted context (could be from meta.context)
          attachmentStyle: attachmentEstimate.primary || 'secure',
          includeAttachmentInsights: true,
          deepAnalysis: true,
          isNewUser
        });
        
        // Map advanced result to simple format for backward compatibility
        toneResult = {
          classification: result.primary_tone,
          confidence: result.confidence
        };
        
        // Store full analysis for suggestions service
        fullToneAnalysis = {
          tone: result.primary_tone,
          confidence: result.confidence,
          ui_tone: 'clear', // Will be set below based on buckets
          emotions: result.emotions,
          analysis: result,
          metaClassifier: result.metaClassifier,
          categories: (result as any).categories || []
        };
        
        logger.info('Advanced tone analysis completed', { 
          primaryTone: result.primary_tone,
          confidence: result.confidence,
          metaClassifier: result.metaClassifier 
        });
      } catch (toneError) {
        logger.error('Tone analysis error:', toneError);
        toneResult = { classification: 'neutral', confidence: 0.5 };
      }
    }

    // Normalize tone to clear/caution/alert (not raw emotion)
    const toneKeyNorm: 'clear' | 'caution' | 'alert' = 
      (toneResult?.classification === 'alert' || toneResult?.classification === 'angry' || toneResult?.classification === 'hostile') ? 'alert' :
      (toneResult?.classification === 'caution' || toneResult?.classification === 'frustrated' || toneResult?.classification === 'sad') ? 'caution' : 'clear';
    
    // Generate suggestions using the dedicated service with tone analysis
    // Pass context hint (if provided) but let the system auto-detect from text
    logger.info('About to call suggestionsService.generateAdvancedSuggestions', {
      textLength: data.text.length,
      context: data.context || 'general',
      userId,
      attachmentStyle: data.attachmentStyle || attachmentEstimate.primary || 'secure',
      toneOverride: data.toneOverride,
      isNewUser
    });

    let suggestionAnalysis;
    try {
      // 1) Analyze tone (override or ML)
      const detectedToneResult = toneResult;

      // 2) Generate suggestions -> returns analysis with flags + context
      suggestionAnalysis = await suggestionsService.generateAdvancedSuggestions(
        data.text,
        contextLabel, // Use extracted context (could be from meta.context)
        {
          id: userId,
          attachment: data.attachmentStyle || attachmentEstimate.primary || 'secure',
          secondary: attachmentEstimate.secondary,
          windowComplete: attachmentEstimate.windowComplete
        },
        {
          maxSuggestions: 3,
          attachmentStyle: data.attachmentStyle || attachmentEstimate.primary || 'secure',
          relationshipStage: data.meta?.relationshipStage,
          conflictLevel: data.meta?.conflictLevel || 'low',
          isNewUser,
          toneAnalysisResult: detectedToneResult,
          fullToneAnalysis: fullToneAnalysis
        }
      );
      logger.info('suggestionsService.generateAdvancedSuggestions completed successfully');
    } catch (suggestionError) {
      logger.error('Error in suggestionsService.generateAdvancedSuggestions:', {
        error: suggestionError,
        message: suggestionError instanceof Error ? suggestionError.message : String(suggestionError),
        stack: suggestionError instanceof Error ? suggestionError.stack : undefined,
        name: suggestionError instanceof Error ? suggestionError.name : 'UnknownError'
      });
      throw suggestionError;
    }
        // Session-based processing - no server-side storage for mass users
    
    // Make the noticings & matches visible for UX / analytics (simulated for session)
    suggestionAnalysis.analysis.flags.phraseEdgeHits = [
      ...(suggestionAnalysis.analysis.flags.phraseEdgeHits || [])
    ];
    (suggestionAnalysis as any).analysis.flags.featureNoticings = [];

    // Session-only processing - no persistent dialogue state for mass users

    // 3) Use detected context for history
    const detectedContext = suggestionAnalysis.analysis?.context?.label || data.context || 'general';
    profile.addCommunication(data.text, detectedContext, toneKeyNorm);

    // 4) Buckets for UI: start from suggestionAnalysis (already normalized) but use normalized tone  
    const baseBuckets = suggestionAnalysis.analysis.toneBuckets?.dist ?? 
      mapToneToBuckets(
        { classification: toneKeyNorm, confidence: toneResult?.confidence || 0.5 },
        'secure',
        detectedContext
      )?.buckets ?? { clear: 1/3, caution: 1/3, alert: 1/3 };

    // 5) Apply attachment adjustments and threshold shifts
    const attachmentStyle = data.attachmentStyle || attachmentEstimate.primary || 'secure';
    const contextKey =
      detectedContext === 'conflict'   ? 'CTX_CONFLICT'  :
      detectedContext === 'planning'   ? 'CTX_PLANNING'  :
      detectedContext === 'boundary'   ? 'CTX_BOUNDARY'  :
      detectedContext === 'repair'     ? 'CTX_REPAIR'    : 'CTX_GENERAL';

    const intensityScore = suggestionAnalysis.analysis?.flags?.intensityScore ?? 0.5;

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
      { classification: toneResult?.classification || 'neutral', confidence: toneResult?.confidence || 0.33 },
      baseBucketsWithFS, // Use FS-adjusted buckets instead of original baseBuckets
      attachmentStyle as any,
      contextKey,
      intensityScore,
      dataLoader.getAttachmentToneWeights()
    );

    const { primary: finalPrimary, distribution: rawBuckets } = applyThresholdShift(
      adjustedBuckets,
      attachmentStyle as any,
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
    
    const response = {
      text: suggestionAnalysis.original_text,
      original_text: suggestionAnalysis.original_text,
      context: suggestionAnalysis.context,
      ui_tone,
      ui_distribution: uiBuckets,
      client_seq: data.client_seq || data.clientSeq,
      original_analysis: {
        tone: toneResult?.classification || ui_tone,
        confidence: toneResult?.confidence || 0.5,
        sentiment: fullToneAnalysis?.sentiment_score || 0,
        sentiment_score: fullToneAnalysis?.sentiment_score || 0,
        intensity: fullToneAnalysis?.intensity || 0.5,
        clarity_score: 0.5, // Default clarity (could be enhanced)
        empathy_score: 0.5, // Default empathy (could be enhanced)
        
        // 🎯 COMPLETE: Include all rich analysis data in response
        linguistic_features: fullToneAnalysis?.linguistic_features,
        context_analysis: fullToneAnalysis?.context_analysis,
        attachment_indicators: fullToneAnalysis?.attachmentInsights || [],
        attachmentInsights: fullToneAnalysis?.attachmentInsights || [],
        communication_patterns: fullToneAnalysis?.communicationPatterns || [],
        
        // UI consistency fields
        ui_tone: fullToneAnalysis?.ui_tone || ui_tone,
        ui_distribution: fullToneAnalysis?.ui_distribution || uiBuckets
      },
      ok: true,
      success: true,
      version: 'v1.0.0-advanced',
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
        
        // 🎯 ENHANCED: Track complete analysis data usage for optimization
        tone_analysis_source: (fullToneAnalysis ? 'coordinator_cache' : 'fresh_analysis') as 'coordinator_cache' | 'fresh_analysis' | 'override',
        complete_analysis_available: !!fullToneAnalysis,
        linguistic_features_used: !!(fullToneAnalysis?.linguistic_features && Object.keys(fullToneAnalysis.linguistic_features).length > 0),
        context_analysis_used: !!(fullToneAnalysis?.context_analysis && Object.keys(fullToneAnalysis.context_analysis).length > 0),
        attachment_insights_count: fullToneAnalysis?.attachmentInsights?.length || 0
      }
    };
    
    // Apply emergency fallback ONLY for true system failures (not guardrail filtering)
    // Check if the service found suggestions initially before any filtering
    const serviceFoundSuggestions = suggestionAnalysis.suggestions && suggestionAnalysis.suggestions.length > 0;
    const wasMainServiceEmpty = !serviceFoundSuggestions;
    const wasMainServiceSuccessful = suggestionAnalysis.success !== false;
    const responseHasSuggestions = Array.isArray(response.suggestions) && response.suggestions.length > 0;
    
    // Only trigger emergency fallback if:
    // 1. Main service found NO suggestions at all (not just filtered them all)
    // 2. Service reported success (not an error)
    // 3. Response has no suggestions after mapping
    const isTrueEmergency = wasMainServiceEmpty && 
                           !responseHasSuggestions &&
                           wasMainServiceSuccessful;
                           
    if (isTrueEmergency) {
      // True emergency: main service found no content at all (not filtering issue)
      logger.error('CRITICAL: Emergency fallback triggered - main service found no suggestions', { 
        userId, 
        text: data.text,
        context: data.context,
        serviceFoundSuggestions,
        responseHasSuggestions,
        serviceSuccess: suggestionAnalysis.success,
        timestamp: new Date().toISOString()
      });
      
      const emergencyFallbacks = ensureAtLeastOneSuggestion([], true);
      response.suggestions = emergencyFallbacks.map((s: any, index: number) => ({
        id: s.id ?? `critical-emergency-${index + 1}`,
        text: s.advice ?? s.text,
        type: 'advice', // ✅ Valid schema enum value instead of 'system_message'
        confidence: 0.05, // Extremely low confidence
        reason: 'Critical system fallback - main suggestions service failed',
        category: 'emotional', // ✅ Valid schema enum value instead of 'system'
        categories: ['emotional'], // ✅ Valid schema enum value
        priority: 999, // Lowest priority
        context_specific: false,
        attachment_informed: false
      }));
      response.metadata.suggestion_count = response.suggestions.length;
      response.metadata.status = 'emergency_fallback'; // Flag for monitoring via existing field
    }
    
    // Log when all suggestions were filtered out (for debugging guardrails)
    else if (serviceFoundSuggestions && !responseHasSuggestions) {
      logger.warn('All suggestions filtered by guardrails', {
        userId,
        text: data.text,
        context: data.context,
        originalSuggestionsCount: suggestionAnalysis.suggestions?.length || 0,
        finalSuggestionsCount: response.suggestions?.length || 0,
        filteringReason: 'guardrails_filtered_all'
      });
    }
    
    // Final response boundary check - should not be needed due to emergency fallback above
    if (!Array.isArray(response.suggestions) || response.suggestions.length === 0) {
      logger.error('Critical: No suggestions at response boundary despite emergency fallback', {
        userId,
        originalText: data.text,
        context: data.context,
        suggestionsServiceLength: suggestionAnalysis?.suggestions?.length || 0,
        timestamp: new Date().toISOString()
      });
      
      // This should never happen if emergency fallback worked correctly
      // Use normalized structure matching main response format
      response.suggestions = [{
        id: 'critical-fallback-1',
        text: 'System temporarily unavailable. Please try again.',
        type: 'advice', // ✅ Valid schema enum value
        confidence: 0.05,
        reason: 'Critical system fallback',
        category: 'emotional', // ✅ Valid schema enum value
        categories: ['emotional'], // ✅ Valid schema enum value
        priority: 999, // Lowest priority
        context_specific: false,
        attachment_informed: false
      }];
      response.metadata.suggestion_count = 1;
    }

    const b = response.ui_distribution;
    if (!b || [b.clear, b.caution, b.alert].some(v => !Number.isFinite(v))) {
      logger.warn('Invalid ui_distribution at boundary; normalizing');
      response.ui_distribution = normalizeBuckets(b || { clear: 1, caution: 0, alert: 0 });
    }
    
    return response;
  } catch (error) {
    logger.error('Advanced suggestions generation failed:', error);
    throw error;
  }
};

const responseHandler = async (req: VercelRequest, res: VercelResponse) => {
  const data = req.body; // Should be already validated by withValidation
  return handler(req, res, data);
};

const wrappedHandler = withErrorHandling(
  withLogging(
    withCors(
      withMethods(['POST'], 
        withValidation(suggestionRequestSchema, 
          withResponseNormalization(normalizeSuggestionResponse, 
            // Enhanced validation: log schema validation results for monitoring
            async (req: VercelRequest, res: VercelResponse) => {
              const response = await responseHandler(req, res);
              
              // Additional validation logging for critical production monitoring
              const validation = suggestionResponseSchema.safeParse(response);
              if (!validation.success) {
                logger.error('Suggestions response schema validation failed', {
                  endpoint: '/api/v1/suggestions',
                  userId: req.headers['x-user-id'] || 'anonymous',
                  errors: validation.error.errors,
                  text_length: req.body?.text?.length || 0,
                  suggestions_count: Array.isArray(response?.suggestions) ? response.suggestions.length : 0,
                  timestamp: new Date().toISOString()
                });
              } else {
                logger.debug('Suggestions response validation passed', {
                  userId: req.headers['x-user-id'] || 'anonymous',
                  suggestions_count: validation.data.suggestions?.length || 0
                });
              }
              
              return response;
            }
          )
        )
      )
    )
  )
);

export default (req: VercelRequest, res: VercelResponse) => {
  return suggestionsRateLimit(req, res, () => {
    return wrappedHandler(req, res);
  });
};

// Pin to iad1 region for reduced latency
export const config = { regions: ['iad1'] };