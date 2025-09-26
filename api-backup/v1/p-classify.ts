// api/v1/p-classify.ts
// P-code classification endpoint for therapy advice routing

import { VercelRequest, VercelResponse } from '@vercel/node';
import { logger } from '../_lib/logger';
import { pickAdvice } from '../_lib/services/advice-router';
import { classifyP, getAllPCodes } from '../_lib/services/p-classifier';
import { dataLoader } from '../_lib/services/dataLoader';

interface PClassifyRequestBody {
  text: string;
  tone?: string;
  context?: string;
  threshold?: number;
  maxResults?: number;
  includeScores?: boolean;
  classifyOnly?: boolean;
}

interface PClassifyResponse {
  success: boolean;
  p_scores: Record<string, number>;
  top_advice_ids?: string[];
  top_advice?: any[];
  scored_advice?: any[];
  total_candidates?: number;
  classification_method?: string;
  available_pcodes?: Record<string, string>;
  error?: string;
}

export default async function handler(
  req: VercelRequest,
  res: VercelResponse
): Promise<VercelResponse | void> {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method === 'GET') {
    // Return available P-codes
    try {
      const availablePCodes = getAllPCodes();
      const response: PClassifyResponse = {
        success: true,
        p_scores: {},
        available_pcodes: availablePCodes
      };
      return res.status(200).json(response);
    } catch (error) {
      logger.error('[P-Classify] Failed to get available P-codes', { error });
      return res.status(500).json({
        success: false,
        p_scores: {},
        error: 'Failed to retrieve available P-codes'
      });
    }
  }

  if (req.method !== 'POST') {
    return res.status(405).json({
      success: false,
      p_scores: {},
      error: 'Method not allowed. Use POST to classify text or GET to retrieve available P-codes.'
    });
  }

  try {
    const {
      text,
      tone,
      context,
      threshold = 0.45,
      maxResults = 5,
      includeScores = false,
      classifyOnly = false
    }: PClassifyRequestBody = req.body || {};

    // Validate input
    if (!text || typeof text !== 'string' || text.trim().length === 0) {
      return res.status(400).json({
        success: false,
        p_scores: {},
        error: 'Text input is required and must be a non-empty string'
      });
    }

    if (text.length > 5000) {
      return res.status(400).json({
        success: false,
        p_scores: {},
        error: 'Text input is too long (max 5000 characters)'
      });
    }

    // If only classification is requested, skip advice routing
    if (classifyOnly) {
      const { p_scores, method } = await classifyP(text, { threshold });
      
      const response: PClassifyResponse = {
        success: true,
        p_scores,
        classification_method: method
      };

      return res.status(200).json(response);
    }

    // Load therapy advice data
    const therapyAdvice = dataLoader.get('therapyAdvice');
    if (!Array.isArray(therapyAdvice)) {
      logger.error('[P-Classify] Therapy advice data not available');
      return res.status(500).json({
        success: false,
        p_scores: {},
        error: 'Therapy advice data not available'
      });
    }

    // Route advice based on P-code classification
    const result = await pickAdvice(text, therapyAdvice, {
      tone,
      context,
      threshold,
      maxResults,
      includeScores
    });

    const response: PClassifyResponse = {
      success: true,
      p_scores: result.p_scores,
      top_advice_ids: result.top.map(advice => advice.id),
      total_candidates: result.total_candidates,
      classification_method: result.classification_method
    };

    // Include full advice objects if requested
    if (includeScores && result.scored) {
      response.scored_advice = result.scored;
    } else {
      response.top_advice = result.top;
    }

    logger.info('[P-Classify] Classification completed', {
      text_length: text.length,
      p_codes_found: Object.keys(result.p_scores).length,
      advice_candidates: result.total_candidates,
      returned_count: result.top.length
    });

    return res.status(200).json(response);

  } catch (error) {
    logger.error('[P-Classify] Classification failed', {
      error: (error as Error).message,
      stack: (error as Error).stack
    });

    return res.status(500).json({
      success: false,
      p_scores: {},
      error: 'Internal server error during P-code classification'
    });
  }
}