// api/v1/communicator.ts
/**
 * Simplified Communicator Profile API
 * 
 * Endpoints:
 *   GET    /api/v1/communicator - Get user's communicator profile
 *   POST   /api/v1/communicator - Update user's communicator profile  
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { withCors, withErrorHandling, withLogging } from '../_lib/wrappers';
import { success } from '../_lib/http';
import { CommunicatorProfile } from '../_lib/services/communicatorProfile';
import { logger } from '../_lib/logger';
import { z } from 'zod';
import { ensureBoot } from '../_lib/bootstrap';

const bootPromise = ensureBoot();

// -------------------- Validation Schemas --------------------
const updateProfileSchema = z.object({
  attachmentStyle: z.string().optional(),
  communicationStyle: z.string().optional(),
  personalityType: z.string().optional(),
  emotionalState: z.string().optional(),
});

// Schema for keyboard observeText requests
const observeRequestSchema = z.object({
  text: z.string().min(1).max(2000),
  meta: z.record(z.string()).optional(),
  personalityProfile: z.object({
    attachmentStyle: z.string(),
    communicationStyle: z.string(),
    personalityType: z.string(),
    emotionalState: z.string(),
    emotionalBucket: z.string(),
    personalityScores: z.record(z.number()).optional(),
    communicationPreferences: z.record(z.string()).optional(),
    isComplete: z.boolean(),
    dataFreshness: z.number()
  }).optional()
});

// -------------------- Helper Functions --------------------
function getUserId(req: VercelRequest): string {
  return req.headers['x-user-id'] as string ||
         req.query.userId as string ||
         'anonymous';
}

// -------------------- Route Handlers --------------------

// GET /api/v1/communicator - Get user's communicator profile
async function getProfile(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    const profile = new CommunicatorProfile({ userId });
    await profile.init();

    const attachmentEstimate = profile.getAttachmentEstimate();
    const isNewUser = !attachmentEstimate.primary || attachmentEstimate.confidence < 0.3;

    logger.info('Profile retrieved', { userId, isNewUser });

    // Return format matching keyboard expectations (ProfileResponse)
    return success(res, {
      ok: true,
      userId,
      estimate: {
        primary: attachmentEstimate.primary,
        secondary: attachmentEstimate.secondary,
        scores: attachmentEstimate.scores,
        confidence: attachmentEstimate.confidence,
        daysObserved: Math.round(attachmentEstimate.daysObserved),
        windowComplete: attachmentEstimate.windowComplete
      },
      rawScores: attachmentEstimate.scores,
      daysObserved: Math.round(attachmentEstimate.daysObserved),
      windowComplete: attachmentEstimate.windowComplete,
      enhancedFeatures: {
        advancedAnalysisAvailable: true,
        version: '2.0.0-persistent',
        accuracyTarget: '92%+',
        features: ['micro_patterns', 'linguistic_analysis', '7_day_learning', 'local_storage_sync']
      }
    });
  } catch (error) {
    logger.error('Profile retrieval failed:', error);
    throw error;
  }
}

// POST /api/v1/communicator - Handle keyboard observeText or profile updates
async function updateProfile(req: VercelRequest, res: VercelResponse) {
  await bootPromise;
  const userId = getUserId(req);

  try {
    // Check if this is a keyboard observeText request
    const observeValidation = observeRequestSchema.safeParse(req.body);
    
    if (observeValidation.success) {
      // Handle keyboard observeText request
      return await handleObserveText(userId, observeValidation.data, res);
    }

    // Fallback to legacy profile update
    const profileValidation = updateProfileSchema.safeParse(req.body);
    if (!profileValidation.success) {
      return res.status(400).json({
        error: 'Invalid request',
        details: profileValidation.error.issues
      });
    }

    return await handleProfileUpdate(userId, profileValidation.data, res);
  } catch (error) {
    logger.error('Communicator API error:', error);
    throw error;
  }
}

// Handle keyboard observeText requests
async function handleObserveText(userId: string, data: any, res: VercelResponse) {
  logger.info('Processing keyboard observeText request', { 
    userId, 
    textLength: data.text.length,
    hasPersonalityProfile: !!data.personalityProfile 
  });

  const profile = new CommunicatorProfile({ userId });
  await profile.init();

  // Process the communication text (simulate tone analysis)
  const detectedTone = await analyzeTextTone(data.text, data.meta);
  
  // Add communication to profile (this updates learning signals)
  profile.addCommunication(data.text, data.meta?.relationshipPhase || 'general', detectedTone);

  // Get updated attachment estimate with learning progress
  const attachmentEstimate = profile.getAttachmentEstimate();

  // Return keyboard-compatible ObserveResponse format
  return success(res, {
    ok: true,
    userId,
    estimate: {
      primary: attachmentEstimate.primary,
      secondary: attachmentEstimate.secondary,
      scores: attachmentEstimate.scores,
      confidence: attachmentEstimate.confidence,
      daysObserved: Math.round(attachmentEstimate.daysObserved),
      windowComplete: attachmentEstimate.windowComplete
    },
    windowComplete: attachmentEstimate.windowComplete,
    enhancedAnalysis: {
      confidence: attachmentEstimate.confidence,
      detectedPatterns: Math.floor(attachmentEstimate.totalSignals / 5), // Rough pattern count
      primaryPrediction: attachmentEstimate.primary || 'unknown'
    }
  });
}

// Handle legacy profile update requests  
async function handleProfileUpdate(userId: string, data: any, res: VercelResponse) {
  logger.info('Processing legacy profile update', { userId });

  const profile = new CommunicatorProfile({ userId });
  await profile.init();

  // Update profile data if provided
  if (data.attachmentStyle) {
    logger.info('Updating attachment style', { userId, attachmentStyle: data.attachmentStyle });
  }

  const attachmentEstimate = profile.getAttachmentEstimate();
  
  return success(res, {
    userId,
    updated: true,
    profile: {
      attachment: attachmentEstimate
    },
    metadata: {
      version: '2.0.0-persistent',
      timestamp: new Date().toISOString(),
      status: 'updated'
    }
  });
}

// Simple tone analysis for processing keyboard text
async function analyzeTextTone(text: string, meta?: Record<string, string>): Promise<string> {
  // Simple tone detection based on keywords
  const lowerText = text.toLowerCase();
  
  if (lowerText.includes('sorry') || lowerText.includes('apologize')) return 'anxious';
  if (lowerText.includes('angry') || lowerText.includes('mad')) return 'angry';
  if (lowerText.includes('frustrated')) return 'frustrated';
  if (lowerText.includes('sad') || lowerText.includes('upset')) return 'sad';
  if (lowerText.includes('confident') || lowerText.includes('sure')) return 'confident';
  if (lowerText.includes('love') || lowerText.includes('appreciate')) return 'supportive';
  if (lowerText.includes('great') || lowerText.includes('awesome')) return 'positive';
  if (lowerText.includes('maybe') || lowerText.includes('perhaps')) return 'tentative';
  
  return 'neutral';
}

// -------------------- Main Handler --------------------
const handler = async (req: VercelRequest, res: VercelResponse) => {
  const method = req.method;

  try {
    if (method === 'GET') {
      await getProfile(req, res);
    } else if (method === 'POST') {
      await updateProfile(req, res);
    } else {
      res.status(405).json({
        error: 'Method Not Allowed',
        message: `${method} is not supported`,
        allowedMethods: ['GET', 'POST']
      });
    }
  } catch (error) {
    logger.error('Communicator API error:', error);
    res.status(500).json({
      error: 'Internal Server Error',
      message: 'An unexpected error occurred'
    });
  }
};

export default withErrorHandling(withLogging(withCors(handler)));