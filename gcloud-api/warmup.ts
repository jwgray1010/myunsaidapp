// api/warmup.ts
// -----------------------------------------------------------------------------
// SpaCy service warmup endpoint for cold start optimization
// Preloads the cache with common patterns to improve first-request performance
// -----------------------------------------------------------------------------

import { Request, Response } from 'express';
import { logger } from './_lib/logger';
import { spacyClient } from './_lib/services/spacyClient';

export default async function handler(req: Request, res: Response) {
  const startTime = Date.now();
  
  try {
    logger.info('[Warmup] Starting SpaCy service warmup');
    
    // Warm up the SpaCy service
    await spacyClient.warmup();
    
    const duration = Date.now() - startTime;
    
    const response = {
      status: 'success',
      service: 'spacy',
      duration_ms: duration,
      cache_status: spacyClient.getProcessingSummary(),
      timestamp: new Date().toISOString()
    };
    
    logger.info('[Warmup] SpaCy warmup completed', response);
    
    res.status(200).json(response);
    
  } catch (error: any) {
    const duration = Date.now() - startTime;
    
    logger.error('[Warmup] SpaCy warmup failed', { 
      error: error.message,
      duration_ms: duration 
    });
    
    res.status(500).json({
      status: 'error',
      service: 'spacy',
      error: error.message,
      duration_ms: duration,
      timestamp: new Date().toISOString()
    });
  }
}