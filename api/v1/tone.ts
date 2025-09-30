import { VercelRequest, VercelResponse } from '@vercel/node';
import { logger } from '../_lib/logger';
import { gcloudClient } from '../_lib/gcloudClient';
import crypto from 'crypto';

// Google Cloud Run endpoint

// Simple request deduplication (in-memory, per instance only)
const requestCache = new Map<string, { result: any; timestamp: number }>();
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

function cleanCache() {
  const now = Date.now();
  for (const [key, entry] of requestCache.entries()) {
    if (now - entry.timestamp > CACHE_TTL_MS) {
      requestCache.delete(key);
    }
  }
}

function getCacheKey(
  textHash: string, 
  clientSeq: number, 
  context?: string, 
  attachmentStyle?: string, 
  rich?: any,
  mode?: string,
  docSeq?: number,
  toneAnalysis?: any
): string {
  const seq = Number(clientSeq) || 1;
  const ctxKey = String(context || 'general').toLowerCase();
  const attachKey = String(attachmentStyle || 'secure').toLowerCase();
  const richKey = rich ? crypto.createHash('sha256').update(JSON.stringify(rich)).digest('hex').substring(0, 8) : 'norich';
  const modeKey = String(mode || 'standard').toLowerCase();
  const docSeqKey = String(docSeq || 'nodoc');
  const toneKey = toneAnalysis 
    ? crypto.createHash('sha256').update(JSON.stringify(toneAnalysis)).digest('hex').substring(0, 8)
    : 'notone';
  
  return `anon:${textHash}:${seq}:${ctxKey}:${attachKey}:${richKey}:${modeKey}:${docSeqKey}:${toneKey}`;
}

function ensureUiFields(resp: any) {
  // Validate required fields
  if (!resp || typeof resp !== 'object') {
    throw new Error('Invalid response: not an object');
  }

  // Check for therapeutic.probs - this is required for proper tone analysis
  const probs = resp.therapeutic?.probs;
  if (!probs || typeof probs !== 'object') {
    throw new Error('Missing required field: therapeutic.probs');
  }

  const { clear, caution, alert } = probs;
  if (typeof clear !== 'number' || typeof caution !== 'number' || typeof alert !== 'number') {
    throw new Error('Invalid therapeutic.probs: must be numbers');
  }

  // If ui_tone already exists, pass through unchanged
  if (resp.ui_tone && resp.ui_distribution) {
    return resp;
  }

  // Compute ui_tone deterministically from therapeutic.probs (argmax)
  const ui_tone = alert >= caution && alert >= clear ? 'alert'
                : caution >= clear ? 'caution' : 'clear';

  // Use actual probabilities, no fallbacks
  const ui_distribution = { clear, caution, alert };

  return { 
    ...resp, 
    ui_tone, 
    ui_distribution,
    contract_version: 'tone-v2'
  };
}

function validateTextSHA256(text: string, expectedHash: string): boolean {
  const actualHash = crypto.createHash('sha256').update(text, 'utf8').digest('hex');
  return actualHash === expectedHash;
}

// Timeout wrapper for Google Cloud calls
function callWithTimeout<T>(promise: Promise<T>, timeoutMs: number = 8000): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => 
      setTimeout(() => reject(Object.assign(new Error('Timeout'), { name: 'AbortError' })), timeoutMs)
    )
  ]);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Request-Id, X-Client-Seq');
  
  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }
  
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }
  
  const requestId = Math.random().toString(36).substring(2, 15);
  
  // Set request ID header for tracing
  res.setHeader('X-Request-Id', requestId);
  
  logger.info(`[${requestId}] POST /v1/tone - Anonymous request`);
  
  try {
    cleanCache(); // Clean expired entries on each request
    
    // Basic validation - iOS v1.5 contract (rich backward-compatible)
    if (!req.body || !req.body.text) {
      return res.status(400).json({
        success: false,
        error: 'Invalid request format. Required: text.',
        contract_version: 'v1.5'
      });
    }
    
    const { text, text_sha256, client_seq, context, attachmentStyle, rich, mode, doc_seq, text_hash, toneAnalysis } = req.body;
    
    // Payload size guard
    if (text.length > 8000) {
      return res.status(413).json({
        success: false,
        error: 'Text too long',
        details: 'Maximum text length is 8000 characters',
        contract_version: 'v1.5'
      });
    }
    
    // SHA256 validation (iOS security check)
    if (text_sha256 && !validateTextSHA256(text, text_sha256)) {
      return res.status(400).json({
        success: false,
        error: 'Text SHA256 mismatch. Provided hash does not match text content.',
        contract_version: 'v1.5'
      });
    }
    
    // Request deduplication check
    const textHash = text_sha256 || text_hash || crypto.createHash('sha256').update(text, 'utf8').digest('hex');
    const cacheKey = getCacheKey(textHash, client_seq || 1, context, attachmentStyle, rich, mode, doc_seq, toneAnalysis);
    const existing = requestCache.get(cacheKey);
    
    if (existing) {
      logger.info(`[${requestId}] Returning cached tone response`);
      // Always use 200 status and envelope format for consistency
      res.setHeader('X-Cache', 'HIT');
      try {
        const validated = ensureUiFields(existing.result);
        return res.status(200).json({
          success: true,
          data: {
            ...validated,
            client_seq: client_seq ?? 1,
            cached: true,
            cacheHitTimestamp: new Date().toISOString()
          },
          cached: true,
          requestId,
          ts: Date.now()
        });
      } catch (error) {
        // Cache contained invalid data, remove it and continue to fresh request
        logger.warn(`[${requestId}] Cached data invalid, removing: ${error instanceof Error ? error.message : 'Unknown error'}`);
        requestCache.delete(cacheKey);
      }
    }
    
    // Forward to Google Cloud Run service via gcloudClient
    const payload = {
      text,
      text_sha256: textHash, // Pass the computed SHA256 hash
      context, 
      attachmentStyle,
      rich,
      mode,
      doc_seq,
      text_hash: textHash, // Also pass as text_hash for backward compatibility
      client_seq: client_seq || 1, // Ensure it's always a positive number
      toneAnalysis
    };

    const response = await callWithTimeout(
      gcloudClient.analyzeTone(payload),
      8000 // 8 second timeout
    );

    // Validate and ensure UI fields are present
    let validatedResponse;
    try {
      validatedResponse = ensureUiFields(response);
    } catch (error) {
      logger.error(`[${requestId}] Google Cloud Run returned invalid tone schema: ${error instanceof Error ? error.message : 'Unknown error'}`);
      return res.status(502).json({
        success: false,
        error: 'Upstream tone analysis service error',
        details: 'Invalid response schema from tone analysis service',
        requestId,
        ts: Date.now()
      });
    }

    // Cache the validated result
    requestCache.set(cacheKey, {
      result: validatedResponse,
      timestamp: Date.now()
    });

    logger.info(`[${requestId}] Tone analysis completed by Google Cloud Run`);

    // Always return consistent envelope format
    res.setHeader('X-Cache', 'MISS');
    return res.status(200).json({
      success: true,
      data: { 
        ...validatedResponse, 
        client_seq: client_seq ?? 1 // ✅ Echo client sequencing back
      },
      cached: false,
      requestId,
      ts: Date.now()
    });
  } catch (error) {
    if ((error as Error).name === 'AbortError') {
      logger.error(`[${requestId}] Google Cloud timeout`);
      return res.status(504).json({
        success: false,
        error: 'Request timeout',
        details: 'Google Cloud service did not respond in time',
        requestId,
        ts: Date.now()
      });
    }
    
    logger.error(`[${requestId}] Tone bridge error:`, error);
    return res.status(500).json({
      success: false,
      error: 'Internal server error',
      details: error instanceof Error ? error.message : 'Unknown error',
      requestId,
      ts: Date.now()
    });
  }
}