// api/v1/suggestions.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging, withResponseNormalization } from '../_lib/wrappers';
import { suggestionsRateLimit } from '../_lib/rateLimit';
import { suggestionRequestSchema } from '../_lib/schemas/suggestionRequest';
import { normalizeSuggestionResponse } from '../_lib/schemas/normalize';
import { toneRequestSchema } from '../_lib/schemas/toneRequest';
import { suggestionsService } from '../_lib/services/suggestions';
import { dataLoader } from '../_lib/services/dataLoader';
import { MLAdvancedToneAnalyzer, mapToneToBuckets } from '../_lib/services/toneAnalysis';
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
    textLength: data.text.length,
    context: data.context, // Context now comes from top-level field
    toneOverride: data.toneOverride,
    features: data.features,
    userId,
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
    
    // FIRST: Get tone analysis - either from override or by running analysis
    logger.info('Determining tone for suggestions...');
    
    let toneResult: { classification: string; confidence: number } | null = null;
    
    // Check if tone is overridden in the request (matching suggestionRequestSchema)
    if (data.toneOverride) {
      toneResult = {
        classification: data.toneOverride, // This will be 'alert', 'caution', or 'clear'
        confidence: 0.9 // High confidence for manual override
      };
      logger.info('Using tone override from request', toneResult);
    } else {
      // Run tone analysis if no override provided
      try {
        const toneAnalyzer = new MLAdvancedToneAnalyzer({ 
          enableSmoothing: true, 
          enableSafetyChecks: true 
        });
        
        const result = await toneAnalyzer.analyzeTone(
          data.text,
          attachmentEstimate.primary || 'secure',
          data.context || 'general', // Context from top-level field
          'general'
        );
        
        if (result?.success) {
          toneResult = {
            classification: result.tone.classification,
            confidence: result.tone.confidence
          };
          logger.info('Tone analysis completed', toneResult);
        } else {
          logger.warn('Tone analysis failed, using fallback');
          toneResult = { classification: 'neutral', confidence: 0.5 };
        }
      } catch (toneError) {
        logger.error('Tone analysis error:', toneError);
        toneResult = { classification: 'neutral', confidence: 0.5 };
      }
    }
    
    // Generate suggestions using the dedicated service with tone analysis
    // Pass context hint (if provided) but let the system auto-detect from text
    logger.info('About to call suggestionsService.generateAdvancedSuggestions with:', {
      textLength: data.text.length,
      context: data.context || 'general', // Context from top-level field
      userId,
      attachmentEstimate,
      toneResult,
      options: {
        maxSuggestions: 3, // Default count since not in schema
        attachmentStyle: data.attachmentStyle || attachmentEstimate.primary || undefined, // Use schema field
        relationshipStage: data.meta?.relationshipStage,
        conflictLevel: data.meta?.conflictLevel || 'low',
        isNewUser,
        toneAnalysisResult: toneResult
      }
    });

    let suggestionAnalysis;
    try {
      suggestionAnalysis = await suggestionsService.generateAdvancedSuggestions(
        data.text,
        data.context || 'general', // Context from top-level field
        {
          id: userId,
          attachment: data.attachmentStyle || attachmentEstimate.primary || 'secure', // Default to secure during learning
          secondary: attachmentEstimate.secondary,
          windowComplete: attachmentEstimate.windowComplete
        },
        {
          maxSuggestions: 3, // Default count since not in schema
          attachmentStyle: data.attachmentStyle || attachmentEstimate.primary || 'secure', // Default to secure during learning
          relationshipStage: data.meta?.relationshipStage,
          conflictLevel: data.meta?.conflictLevel || 'low',
          isNewUser,
          toneAnalysisResult: toneResult
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

    // Use the auto-detected context for profile history (more accurate than hint)
    const detectedContext = suggestionAnalysis.analysis?.context?.label || data.context || 'general';
    profile.addCommunication(data.text, detectedContext, toneResult?.classification || 'neutral');
    
    // Map tone → UI buckets so iOS pill can colorize immediately
    const bucketed = mapToneToBuckets(
      { classification: toneResult?.classification || 'neutral', confidence: toneResult?.confidence || 0.33 },
      data.attachmentStyle || attachmentEstimate.primary || 'secure',
      detectedContext || 'general'
    );
    const baseBuckets = bucketed?.buckets || { clear: 1/3, caution: 1/3, alert: 1/3 };
    
    // Apply attachment-style tone adjustments
    const attachmentStyle = data.attachmentStyle || attachmentEstimate.primary || 'secure';
    const contextKey = (detectedContext === 'conflict' ? 'CTX_CONFLICT'
                     : detectedContext === 'planning' ? 'CTX_PLANNING'
                     : detectedContext === 'boundary' ? 'CTX_BOUNDARY'
                     : detectedContext === 'repair'   ? 'CTX_REPAIR'
                     : 'CTX_GENERAL');
    
    // Get attachment tone weights config and apply adjustments
    const attachmentToneConfig = dataLoader.getAttachmentToneWeights();
    const intensityScore = suggestionAnalysis.analysis?.flags?.intensityScore || 0.5;
    
    const adjustedBuckets = adjustToneByAttachment(
      { classification: toneResult?.classification || 'neutral', confidence: toneResult?.confidence || 0.33 },
      baseBuckets,
      attachmentStyle as any,
      contextKey,
      intensityScore,
      attachmentToneConfig
    );
    
    // Apply threshold shift for final primary bucket selection
    const { primary: finalPrimary, distribution: uiBuckets } = applyThresholdShift(
      adjustedBuckets,
      attachmentStyle as any,
      attachmentToneConfig
    );
    
    const ui_tone = finalPrimary;
    
    const processingTime = Date.now() - startTime;
    
    logger.info('Advanced suggestions generated', { 
      processingTime,
      count: suggestionAnalysis.suggestions.length,
      userId,
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
        tone: ui_tone,
        sentiment: 0, // Default sentiment
        clarity_score: 0.5, // Default clarity
        empathy_score: 0.5, // Default empathy
        attachment_indicators: [],
        communication_patterns: []
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
        processing_time_ms: processingTime,
        model_version: 'v1.0.0-advanced',
        attachment_informed: true,
        suggestion_count: suggestionAnalysis.suggestions.length,
        status: 'active' // Always active - learning happens in background
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