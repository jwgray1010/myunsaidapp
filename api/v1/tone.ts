// api/v1/tone.ts - Pure bridge to Google Cloud
import { VercelRequest, VercelResponse } from '@vercel/node';
import { gcloudClient } from '../_lib/gcloudClient';
import { logger } from '../_lib/logger';
import crypto from 'crypto';

// Simple token authentication
function requireSimpleToken(req: VercelRequest, res: VercelResponse): boolean {
  const hdr = (req.headers['authorization'] || req.headers['Authorization']) as string | undefined;
  const match = hdr && /^Bearer\s+(.+)$/i.exec(hdr.trim());
  const token = match?.[1] ?? null;
  const ok = token && process.env.API_BEARER_TOKEN && token === process.env.API_BEARER_TOKEN;
  if (!ok) {
    res.status(401).json({ success: false, error: 'AUTH_REQUIRED' });
  }
  return !!ok;
}

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
  
  // Require authentication for all non-OPTIONS requests
  if (!requireSimpleToken(req, res)) return;
  
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
      return res.status(200).json({
        success: true,
        data: {
          ...existing.result,
          client_seq: client_seq ?? 1, // ✅ Echo client sequencing for cached responses
          cached: true,
          cacheHitTimestamp: new Date().toISOString()
        },
        cached: true,
        requestId,
        ts: Date.now()
      });
    }
    
    // Bridge rich v1.5 envelope to Google Cloud - forward optional rich context
    const response = await callWithTimeout(
      gcloudClient.analyzeTone({
        text,
        context: context || 'general', 
        attachmentStyle: attachmentStyle || 'secure',
        rich,    // Forward rich context for local heuristics
        mode,    // Forward iOS coordinator mode
        doc_seq, // Forward iOS coordinator document sequence
        text_hash, // Forward iOS coordinator text hash
        client_seq, // Forward iOS coordinator client sequence
        toneAnalysis // Forward any existing tone analysis
      }),
      8000 // 8 second timeout for tone analysis
    );
    
    // Cache the result
    requestCache.set(cacheKey, {
      result: response,
      timestamp: Date.now()
    });
    
    logger.info(`[${requestId}] Tone analysis completed by Google Cloud`);
    
    // Always return consistent envelope format
    res.setHeader('X-Cache', 'MISS');
    return res.status(200).json({
      success: true,
      data: { 
        ...response, 
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