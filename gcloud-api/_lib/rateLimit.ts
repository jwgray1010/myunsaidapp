// api/_lib/rateLimit.ts
/**
 * IMPROVED RATE LIMITING FOR UNSAID API
 * 
 * Key improvements:
 * - User + IP based keys (prevents mobile throttling)
 * - Proper failure skipping (401/402/4xx don't consume quota)
 * - Reasonable limits for chatty endpoints
 * - Automatic skipping of OPTIONS/health requests
 * - Retry-After headers for better client handling
 * 
 * USAGE EXAMPLES:
 * 
 * // Tone analysis endpoint (chatty, needs permissive limits)
 * import { toneAnalysisRateLimit } from '../_lib/rateLimit';
 * import { withAuth } from '../_lib/auth';
 * 
 * export default toneAnalysisRateLimit(async (req, res) => {
 *   return withAuth(async (req, res, auth) => {
 *     // Your tone analysis logic here
 *     return res.json({ tone: 'clear' });
 *   })(req, res);
 * });
 * 
 * // Suggestions endpoint
 * import { suggestionsRateLimit } from '../_lib/rateLimit';
 * 
 * export default suggestionsRateLimit(async (req, res) => {
 *   return withAuth(async (req, res, auth) => {
 *     // Your suggestions logic here
 *     return res.json({ suggestions: [] });
 *   })(req, res);
 * });
 * 
 * WHY THIS PREVENTS UI BLOCKING:
 * - Failed auth (401) doesn't consume quota
 * - Failed trial (402) doesn't consume quota  
 * - Anonymous users get separate buckets
 * - Mobile users don't throttle each other
 * - Reasonable limits prevent keyboard spam from hitting limits
 */
import { Request, Response } from 'express';
import { logger } from './logger';

interface RateLimitConfig {
  windowMs: number;
  maxRequests: number;
  keyGenerator?: (req: Request) => string;
  skipSuccessfulRequests?: boolean;
  skipFailedRequests?: boolean;
  skip?: (req: Request) => boolean;
  standardHeaders?: boolean;
  legacyHeaders?: boolean;
  message?: string;
}

interface RateLimitStore {
  [key: string]: {
    count: number;
    resetTime: number;
    firstRequest: number;
  };
}

// Simple in-memory store (in production, use Redis or similar)
const store: RateLimitStore = {};

// Cleanup expired entries periodically
setInterval(() => {
  const now = Date.now();
  Object.keys(store).forEach(key => {
    if (store[key].resetTime < now) {
      delete store[key];
    }
  });
}, 60000); // Cleanup every minute

// Helper: Extract first IP from x-forwarded-for or fallback
function firstIp(req: Request): string {
  const xff = (req.headers['x-forwarded-for'] as string) || '';
  const ip = xff.split(',')[0]?.trim() || 
             (req.headers['x-real-ip'] as string) ||
             req.socket?.remoteAddress ||
             '';
  return ip || 'ip:unknown';
}

// Improved key generator: user + IP to prevent IP-based throttling issues
const defaultKeyGenerator = (req: Request) => {
  const user = (req.headers['x-user-id'] as string)?.trim() || 'user:anon';
  return `${user}:${firstIp(req)}`;
};

export function createRateLimit(config: RateLimitConfig) {
  const {
    windowMs = 15 * 60 * 1000, // 15 minutes
    maxRequests = 100,
    keyGenerator = defaultKeyGenerator,
    skipSuccessfulRequests = false,
    skipFailedRequests = false,
    skip = (req) => {
      // Default skip: true for OPTIONS, /api/health, /api/metrics (with query params)
      return req.method === 'OPTIONS' || 
             req.url?.startsWith('/api/health') || 
             req.url?.startsWith('/api/metrics');
    },
    standardHeaders = true,
    legacyHeaders = false,
    message = 'Too many requests, please try again later.'
  } = config;

  return (req: Request, res: Response, next: () => void) => {
    // Skip rate limiting if configured
    if (skip(req)) {
      return next();
    }

    const key = keyGenerator(req);
    const now = Date.now();

    // Rolling cleanup: Clean up expired entries when accessing any key
    Object.keys(store).forEach(k => {
      if (store[k] && store[k].resetTime < now) {
        delete store[k];
      }
    });

    // Clean up expired entries for this specific key
    if (store[key] && store[key].resetTime < now) {
      delete store[key];
    }

    // Initialize or get current count
    if (!store[key]) {
      store[key] = { 
        count: 0, 
        resetTime: now + windowMs,
        firstRequest: now
      };
    }

    const entry = store[key];
    const isWithinWindow = (now - entry.firstRequest) < windowMs;

    // Reset if window has expired
    if (!isWithinWindow) {
      entry.count = 0;
      entry.resetTime = now + windowMs;
      entry.firstRequest = now;
    }

    // Check if limit exceeded
    if (entry.count >= maxRequests) {
      const timeUntilReset = Math.ceil((entry.resetTime - now) / 1000);
      
      // Check if headers already sent to prevent duplicate responses
      if (res.headersSent) {
        logger.warn('Rate limit exceeded but headers already sent', { 
          key, 
          count: entry.count, 
          limit: maxRequests,
          route: req.url 
        });
        return;
      }
      
      // Set standard rate limit headers (RateLimit-*)
      if (standardHeaders) {
        res.setHeader('RateLimit-Limit', maxRequests);
        res.setHeader('RateLimit-Remaining', 0);
        res.setHeader('RateLimit-Reset', new Date(entry.resetTime).toISOString());
        res.setHeader('Retry-After', timeUntilReset);
      }

      // Set legacy headers (X-RateLimit-*) when legacyHeaders enabled
      if (legacyHeaders) {
        res.setHeader('X-RateLimit-Limit', maxRequests);
        res.setHeader('X-RateLimit-Remaining', 0);
        res.setHeader('X-RateLimit-Reset', timeUntilReset);
      }
      
      logger.warn('Rate limit exceeded', { 
        key, 
        count: entry.count, 
        limit: maxRequests,
        resetIn: timeUntilReset,
        route: req.url,
        method: req.method,
        userAgent: req.headers['user-agent']
      });
      
      res.status(429).json({
        error: true,
        message,
        retryAfter: timeUntilReset,
        limit: maxRequests,
        remaining: 0,
        reset: new Date(entry.resetTime).toISOString()
      });
      return;
    }

    // Increment counter (before processing request)
    entry.count++;

    // Track the response to potentially skip counting
    const originalJson = res.json.bind(res);
    const originalEnd = res.end.bind(res);
    
    const maybeDecrement = () => {
      const status = res.statusCode;
      if ((skipSuccessfulRequests && status < 400) ||
          (skipFailedRequests && status >= 400)) {
        entry.count = Math.max(0, entry.count - 1);
      }
    };

    res.json = (body: any) => { 
      maybeDecrement();
      // Check if headers already sent before calling original json method
      if (!res.headersSent) {
        return originalJson(body);
      }
      // Return the response object to maintain the correct return type
      return res;
    };
    res.end = (chunk?: any, encoding?: any, cb?: any) => { 
      maybeDecrement(); 
      return originalEnd(chunk, encoding as any, cb); 
    };

    // Set rate limit headers
    const remaining = Math.max(0, maxRequests - entry.count);
    const resetTime = new Date(entry.resetTime);
    
    if (standardHeaders) {
      res.setHeader('RateLimit-Limit', maxRequests);
      res.setHeader('RateLimit-Remaining', remaining);
      res.setHeader('RateLimit-Reset', resetTime.toISOString());
    }

    if (legacyHeaders) {
      res.setHeader('X-RateLimit-Limit', maxRequests);
      res.setHeader('X-RateLimit-Remaining', remaining);
      res.setHeader('X-RateLimit-Reset', Math.ceil((entry.resetTime - now) / 1000));
    }

    next();
  };
}

// Default rate limiters (matching JavaScript version patterns)
export const defaultRateLimit = createRateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  maxRequests: 100,
  message: 'Too many requests from this IP, please try again later.'
});

export const strictRateLimit = createRateLimit({
  windowMs: 60 * 1000, // 1 minute
  maxRequests: 10,
  message: 'Rate limit exceeded. Please slow down your requests.'
});

export const authRateLimit = createRateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  maxRequests: 5,
  keyGenerator: (req) => `auth:${req.headers['x-forwarded-for'] || req.connection?.remoteAddress || 'unknown'}`,
  message: 'Too many authentication attempts, please try again later.'
});

// API-specific rate limiters
export const apiRateLimit = createRateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  maxRequests: 1000, // Higher limit for API usage
  message: 'API rate limit exceeded. Please upgrade your plan for higher limits.',
  skipSuccessfulRequests: false,
  skipFailedRequests: true // Don't count failed requests against the limit
});

// Tone analysis - more permissive for chatty keyboard usage
export const toneAnalysisRateLimit = createRateLimit({
  windowMs: 10 * 1000, // 10 seconds - shorter window
  maxRequests: 20, // 20 requests per 10 seconds
  message: 'Tone analysis rate limit exceeded. Please wait a moment before continuing.',
  skipSuccessfulRequests: false,
  skipFailedRequests: true
});

// Suggestions - moderate limits
export const suggestionsRateLimit = createRateLimit({
  windowMs: 60 * 1000, // 1 minute
  maxRequests: 60, // 60 requests per minute
  message: 'Suggestions rate limit exceeded. Please wait before requesting more suggestions.',
  skipSuccessfulRequests: false,
  skipFailedRequests: true
});

export const uploadRateLimit = createRateLimit({
  windowMs: 60 * 1000, // 1 minute
  maxRequests: 5, // Limited uploads per minute
  message: 'Upload rate limit exceeded. Please wait before uploading again.'
});

// Rate limiter for different user tiers
export function createTieredRateLimit(userTier: 'free' | 'premium' | 'enterprise' = 'free') {
  const limits = {
    free: { windowMs: 15 * 60 * 1000, maxRequests: 100 },
    premium: { windowMs: 15 * 60 * 1000, maxRequests: 1000 },
    enterprise: { windowMs: 15 * 60 * 1000, maxRequests: 10000 }
  };

  const config = limits[userTier];
  return createRateLimit({
    ...config,
    message: `${userTier} tier rate limit exceeded. Consider upgrading for higher limits.`,
    keyGenerator: (req) => {
      // Include user tier in the key for separate buckets
      const ip = firstIp(req);
      return `${userTier}:${ip}`;
    }
  });
}