// vercel-api/v1/tone.ts - Pure bridge to Google Cloud
import { VercelRequest, VercelResponse } from '@vercel/node';
import { gcloudClient } from '../_lib/services/gcloudClient';
import { logger } from '../_lib/logger';
import crypto from 'crypto';

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

function getCacheKey(userId: string, textHash: string, clientSeq: number): string {
  return `${userId}:${textHash}:${clientSeq}`;
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
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Request-Id, X-User-Id');
  
  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }
  
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }
  
  const requestId = Math.random().toString(36).substring(2, 15);
  const userId = req.headers['x-user-id'] as string || req.body?.userId || 'anonymous';
  
  logger.info(`[${requestId}] POST /v1/tone - User: ${userId}`);
  
  try {
    cleanCache(); // Clean expired entries on each request
    
    // Basic validation - iOS v1 contract essentials
    if (!req.body || !req.body.text) {
      return res.status(400).json({
        success: false,
        error: 'Invalid request format. Required: text.',
        contract_version: 'v1'
      });
    }
    
    const { text, text_sha256, client_seq, context, attachmentStyle } = req.body;
    
    // SHA256 validation (iOS security check)
    if (text_sha256 && !validateTextSHA256(text, text_sha256)) {
      return res.status(400).json({
        success: false,
        error: 'Text SHA256 mismatch. Provided hash does not match text content.',
        contract_version: 'v1'
      });
    }
    
    // Request deduplication check
    const textHash = text_sha256 || crypto.createHash('sha256').update(text, 'utf8').digest('hex');
    const cacheKey = getCacheKey(userId, textHash, client_seq || 1);
    const existing = requestCache.get(cacheKey);
    
    if (existing) {
      logger.info(`[${requestId}] Returning cached tone response`);
      return res.status(208).json({
        ...existing.result,
        cached: true,
        cache_hit_timestamp: new Date().toISOString()
      });
    }
    
    // Bridge minimal envelope to Google Cloud - let it do all the heavy lifting
    const response = await callWithTimeout(
      gcloudClient.analyzeTone({
        text,
        context: context || 'general', 
        attachmentStyle: attachmentStyle || 'secure',
        userId
      }),
      8000 // 8 second timeout for tone analysis
    );
    
    if (response.success) {
      // Cache the result
      requestCache.set(cacheKey, {
        result: response.data,
        timestamp: Date.now()
      });
      
      logger.info(`[${requestId}] Tone analysis completed by Google Cloud`);
      return res.status(200).json(response.data);
    } else {
      logger.error(`[${requestId}] Google Cloud tone analysis error: ${response.error}`);
      return res.status(500).json({
        error: 'Tone analysis failed',
        details: response.error
      });
    }
  } catch (error) {
    if ((error as Error).name === 'AbortError') {
      logger.error(`[${requestId}] Google Cloud timeout`);
      return res.status(504).json({
        error: 'Request timeout',
        details: 'Google Cloud service did not respond in time'
      });
    }
    
    logger.error(`[${requestId}] Tone bridge error:`, error);
    return res.status(500).json({
      error: 'Internal server error',
      details: error instanceof Error ? error.message : 'Unknown error'
    });
  }
}