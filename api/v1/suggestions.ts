// api/v1/suggestions.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging, withResponseNormalization } from '../_lib/wrappers';
import { suggestionsRateLimit } from '../_lib/rateLimit';
import { suggestionRequestSchema } from '../_lib/schemas/suggestionRequest';
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

const handler = async (req: VercelRequest, res: VercelResponse, data: any) => {
  await bootPromise;
  const startTime = Date.now();
  const userId = getUserId(req);
  
  logger.info('Processing advanced suggestions request', { 
    userId,
    textLength: data.text.length,
    context: data.context,
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
          context: data.context || 'general',
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
          metaClassifier: result.metaClassifier
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
        data.context || 'general',
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

    const { primary: finalPrimary, distribution: uiBuckets } = applyThresholdShift(
      adjustedBuckets,
      attachmentStyle as any,
      dataLoader.getAttachmentToneWeights()
    );

    const ui_tone = finalPrimary; // 'clear' | 'caution' | 'alert'
    
    // Session-only processing - no persistent dialogue state for mass users
    
    const processingTime = Date.now() - startTime;
    
    logger.info('Advanced suggestions generated', { 
      userId,
      processingTimeMs: processingTime,
      pickedSize: suggestionAnalysis.suggestions.length,
      attachment: attachmentEstimate.primary,
      isNewUser
    });
    
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
      suggestions: suggestionAnalysis.suggestions.map((s: any, index: number) => ({
        id: index + 1,
        text: s.text,
        type: s.type,
        confidence: s.confidence,
        reason: s.reason,
        category: s.category,
        priority: s.priority,
        context_specific: s.context_specific,
        attachment_informed: s.attachment_informed
      })),
      analysis_meta: suggestionAnalysis.analysis_meta,
      metadata: {
        processingTimeMs: processingTime,
        model_version: 'v1.0.0-advanced',
        attachment_informed: true,
        suggestion_count: suggestionAnalysis.suggestions.length,
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
          withResponseNormalization(normalizeSuggestionResponse, responseHandler)
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