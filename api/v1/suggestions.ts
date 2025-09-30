import type { VercelRequest, VercelResponse } from '@vercel/node';
import { gcloudClient } from '../_lib/gcloudClient';
import { logger } from '../_lib/logger';

// Minimal CORS helper
function setCors(res: VercelResponse) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Request-Id, X-Client-Seq');
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  setCors(res);

  // Always answer preflight
  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ success: false, error: 'Method Not Allowed' });
  }

  const requestId = Math.random().toString(36).substring(2, 15);
  res.setHeader('X-Request-Id', requestId);
  
  logger.info(`[${requestId}] POST /v1/suggestions - Anonymous request`);

  try {
    // Accept either raw text or a SHA-only payload (your client sometimes sends text, sometimes just text_sha256)
    const {
      text,
      text_sha256,
      client_seq,
      context,
      features,
      conversationHistory,
      attachmentStyle,
      compose_id,
      meta,
      userId,
      user_profile,
      maxSuggestions,
      input_length,
      rich,
      toneAnalysis,
    } = (req.body ?? {}) as Record<string, any>;

    // Basic validation (adjust as needed)
    if (!text && !text_sha256) {
      return res.status(400).json({ success: false, error: 'Missing text or text_sha256' });
    }

    // Normalize client_seq to always be ≥1 for consistent correlation
    const normalizedClientSeq = Math.max(Number(client_seq) || 1, 1);

    const payload = {
      text,
      text_sha256,
      client_seq: normalizedClientSeq,
      context,
      features,
      conversationHistory,
      attachmentStyle,
      compose_id,
      meta,
      userId,
      user_profile,
      maxSuggestions,
      input_length,
      rich,
      toneAnalysis,
    };

    // If your client sometimes omits text, your backend needs to be able to handle text_sha256-only requests.
    const response: unknown = await gcloudClient.generateSuggestions(payload);

    // Ensure we always spread an object
    const responseObj =
      response && typeof response === 'object'
        ? (response as Record<string, unknown>)
        : { value: response };

    logger.info(`[${requestId}] Suggestions generated successfully by Google Cloud`);

    return res.status(200).json({
      success: true,
      data: {
        ...responseObj,
        client_seq: normalizedClientSeq,
        compose_id,
      },
      cached: false,
      requestId,
      ts: Date.now(),
    });
  } catch (err: any) {
    logger.error(`[${requestId}] Suggestions error:`, err);
    
    if (err?.name === 'AbortError') {
      return res.status(504).json({ 
        success: false, 
        error: 'Request timeout',
        details: 'Google Cloud service did not respond in time',
        requestId,
        ts: Date.now()
      });
    }
    
    return res.status(500).json({ 
      success: false, 
      error: err?.message ?? 'Internal Server Error',
      requestId,
      ts: Date.now()
    });
  }
}
