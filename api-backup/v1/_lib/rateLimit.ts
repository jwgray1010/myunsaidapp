// api/v1/_lib/rateLimit.ts
/**
 * Lightweight rate limiting for Vercel v1 endpoints
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { error } from './http';

// Simple in-memory rate limiting (for demo - use Redis in production)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

function createRateLimit(maxRequests: number, windowMs: number) {
  return async (req: VercelRequest, res: VercelResponse, next: Function) => {
    const key = req.headers['x-forwarded-for'] || req.connection?.remoteAddress || 'unknown';
    const now = Date.now();
    
    const record = rateLimitStore.get(key as string);
    
    if (!record || now > record.resetTime) {
      rateLimitStore.set(key as string, { count: 1, resetTime: now + windowMs });
      return next();
    }
    
    if (record.count >= maxRequests) {
      return error(res, 'Rate limit exceeded', 429);
    }
    
    record.count++;
    return next();
  };
}

export const toneAnalysisRateLimit = createRateLimit(100, 60000); // 100 per minute
export const suggestionsRateLimit = createRateLimit(50, 60000);  // 50 per minute