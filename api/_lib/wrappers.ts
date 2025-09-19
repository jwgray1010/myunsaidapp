// api/_lib/wrappers.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { z } from 'zod';
import { handleCors } from './cors';
import { logger } from './logger';
import { error, methodNotAllowed, badRequest, tooManyRequests, internalError } from './http';
import { handleError } from './middleware/errorHandler';

export type Handler = (req: VercelRequest, res: VercelResponse) => Promise<void> | void;

export function withCors(handler: Handler): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    const handled = handleCors(req, res);
    if (handled) return;
    
    return handler(req, res);
  };
}

export function withMethods(allowedMethods: string[], handler: Handler): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    if (!allowedMethods.includes(req.method || '')) {
      return methodNotAllowed(res, allowedMethods);
    }
    
    return handler(req, res);
  };
}

export function withValidation<T>(schema: z.ZodSchema<T>, handler: (req: VercelRequest, res: VercelResponse, data: T) => Promise<void> | void): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      let data: any = {};
      
      if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
        // Parse body for POST/PUT/PATCH requests
        const body = await new Promise<string>((resolve) => {
          let bodyStr = '';
          req.on('data', (chunk) => {
            bodyStr += chunk.toString();
          });
          req.on('end', () => {
            resolve(bodyStr);
          });
        });
        
        if (body) {
          try {
            data = JSON.parse(body);
          } catch (err) {
            return badRequest(res, 'Invalid JSON in request body');
          }
        }
      } else {
        // Use query params for GET requests
        data = req.query || {};
      }
      
      const validatedData = schema.parse(data);
      return handler(req, res, validatedData);
    } catch (err) {
      if (err instanceof z.ZodError) {
        const errorMessage = err.errors.map(e => `${e.path.join('.')}: ${e.message}`).join(', ');
        return badRequest(res, `Validation failed: ${errorMessage}`);
      }
      
      logger.error('Validation wrapper error:', err);
      return internalError(res, 'Validation error');
    }
  };
}

export function withErrorHandling(handler: Handler): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      await handler(req, res);
    } catch (err) {
      // Use the advanced error handler from middleware
      handleError(err, req, res);
    }
  };
}

export function withLogging(handler: Handler): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    const start = Date.now();
    const { method, url } = req;
    
    logger.info(`${method} ${url} - Started`);
    
    // Monkey patch res.end to capture response
    const originalEnd = res.end;
    res.end = function(chunk?: any, encoding?: any) {
      const duration = Date.now() - start;
      logger.info(`${method} ${url} - ${res.statusCode} ${duration}ms`);
      return originalEnd.call(this, chunk, encoding);
    };
    
    return handler(req, res);
  };
}

// Rate limiting for serverless - should use external service (Redis, KV, etc.)
// This is a placeholder that sets headers but doesn't actually limit
export function withRateLimit(windowMs: number = 15 * 60 * 1000, maxRequests: number = 100): (handler: Handler) => Handler {
  return (handler: Handler): Handler => {
    return async (req: VercelRequest, res: VercelResponse) => {
      // For serverless, rate limiting should be handled by:
      // 1. Vercel Edge Functions rate limiting
      // 2. External service (Redis, Upstash, etc.)
      // 3. API Gateway rate limiting
      
      // Set rate limit headers for client awareness
      res.setHeader('X-RateLimit-Limit', maxRequests.toString());
      res.setHeader('X-RateLimit-Remaining', maxRequests.toString());
      res.setHeader('X-RateLimit-Reset', Math.ceil((Date.now() + windowMs) / 1000).toString());
      
      // TODO: Implement actual rate limiting with external service
      // Example with Upstash Redis:
      // const redis = new Redis({ url: process.env.UPSTASH_REDIS_REST_URL });
      // const key = `rate_limit:${ip}:${Math.floor(Date.now() / windowMs)}`;
      // const count = await redis.incr(key);
      // if (count === 1) await redis.expire(key, Math.ceil(windowMs / 1000));
      // if (count > maxRequests) return tooManyRequests(res);
      
      return handler(req, res);
    };
  };
}

// Response validation wrapper
export function withResponseNormalization<T>(
  normalizer: (raw: unknown) => T,
  handler: (req: VercelRequest, res: VercelResponse) => Promise<T> | T
): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      const result = await handler(req, res);
      const normalized = normalizer(result);
      
      res.status(200).json(normalized);
    } catch (err) {
      logger.error('Response normalization error:', err);
      throw err; // Let error handling wrapper handle it
    }
  };
}

export function compose(...wrappers: ((handler: Handler) => Handler)[]): (handler: Handler) => Handler {
  return (handler: Handler): Handler => {
    return wrappers.reduceRight((wrapped, wrapper) => wrapper(wrapped), handler);
  };
}