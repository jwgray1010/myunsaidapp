// api/v1/suggestions.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withMethods, withValidation, withErrorHandling, withLogging, withResponseNormalization } from '../_lib/wrappers';
import { suggestionsRateLimit } from '../_lib/rateLimit';
import { suggestionRequestSchema } from '../_lib/schemas/suggestionRequest';
import { normalizeSuggestionResponse } from '../_lib/schemas/normalize';
import { suggestionsService } from '../_lib/services/suggestions';
import { dataLoader } from '../_lib/services/dataLoader';
import { MLAdvancedToneAnalyzer, mapToneToBuckets } from '../_lib/services/toneAnalysis';
import { adjustToneByAttachment, applyThresholdShift } from '../_lib/services/utils/attachmentToneAdjust';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { FeatureSpotterStore } from '../_lib/services/featureSpotter.store';
import { DialogueStateStore } from '../_lib/services/dialogueState';
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
          toneAnalysisResult: detectedToneResult
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

    // FeatureSpotter integration - run pattern detection
    const fs = new FeatureSpotterStore(userId);
    const fsRun = fs.run(data.text, {
      hasNegation: suggestionAnalysis.analysis.flags.hasNegation,
      hasSarcasm: suggestionAnalysis.analysis.flags.hasSarcasm
    });

    // Make the noticings & matches visible for UX / analytics
    suggestionAnalysis.analysis.flags.phraseEdgeHits = [
      ...(suggestionAnalysis.analysis.flags.phraseEdgeHits || []),
      ...fsRun.matches.map(m => m.featureId)
    ];
    (suggestionAnalysis as any).analysis.flags.featureNoticings = fsRun.noticings;

    // Update dialogue state
    new DialogueStateStore(userId).update({
      lastContext: (suggestionAnalysis.context || 'general') as any,
      lastTone: undefined // Will be set after ui_tone calculation
    }, data.text);

    // Aggregate into profile learning
    fs.aggregateToProfile(fsRun, profile);

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

    // Apply feature spotter attachment hints to base buckets
    const attachmentHintDelta = fsRun.attachmentHints[attachmentStyle] || 0;
    const baseBucketsWithFS = {
      clear: Math.max(0, baseBuckets.clear + (fsRun.toneHints.clear || 0)),
      caution: Math.max(0, baseBuckets.caution + (fsRun.toneHints.caution || 0)),
      alert: Math.max(0, baseBuckets.alert + (fsRun.toneHints.alert || 0))
    };
    // Normalize after FS hints
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
    
    // Update dialogue state with final tone
    new DialogueStateStore(userId).update({
      lastContext: (suggestionAnalysis.context || 'general') as any,
      lastTone: ui_tone as any
    });
    
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
        processingTimeMs: processingTime,
        model_version: 'v1.0.0-advanced',
        attachment_informed: true,
        suggestion_count: suggestionAnalysis.suggestions.length,
        status: 'active', // Always active - learning happens in background
        feature_noticings: fsRun.noticings
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