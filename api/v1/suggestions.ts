// api/v1/suggestions.ts
import type { VercelRequest, VercelResponse } from '@vercel/node';
import { gcloudClient } from '../_lib/gcloudClient';
import { logger } from '../_lib/logger';

// --- Types -------------------------------------------------------------------
type AnyObject = Record<string, unknown>;

interface SuggestionRequest extends AnyObject {
  text?: string;
  text_sha256?: string;
  client_seq?: number | string;
  context?: string;
  features?: string[] | AnyObject;
  conversationHistory?: Array<AnyObject>;
  attachmentStyle?: string;
  compose_id?: string;
  meta?: AnyObject;
  userId?: string;
  user_profile?: AnyObject;
  maxSuggestions?: number;
  input_length?: number;
  rich?: AnyObject;
  toneAnalysis?: AnyObject;
}

// --- Helpers -----------------------------------------------------------------
function setCors(res: VercelResponse) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, X-Request-Id, X-Client-Seq'
  );
}

function requestIdHeader(res: VercelResponse): string {
  const requestId =
    Math.random().toString(36).slice(2, 10) +
    Math.random().toString(36).slice(2, 10);
  res.setHeader('X-Request-Id', requestId);
  return requestId;
}

// --- Handler -----------------------------------------------------------------
export default async function handler(req: VercelRequest, res: VercelResponse) {
  setCors(res);
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ success: false, error: 'Method Not Allowed' });

  return res.status(200).json({
    success: true,
    echo: { method: req.method, body: req.body ?? null },
    ts: Date.now(),
  });
}
