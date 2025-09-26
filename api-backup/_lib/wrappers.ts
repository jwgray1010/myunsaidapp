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
        // Use parsed body when available; fallback to manual parse
        if (typeof (req as any).body === 'object' && (req as any).body !== null) {
          data = (req as any).body;
        } else {
          // Fallback to streaming and manual parse
          const raw = await new Promise<string>((resolve) => {
            let s = '';
            req.on('data', c => s += c);
            req.on('end', () => resolve(s));
          });
          
          if (raw) {
            try {
              data = JSON.parse(raw);
            } catch {
              return badRequest(res, 'Invalid JSON');
            }
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
    let logged = false;
    
    logger.info(`${method} ${url} - Started`);
    
    // Function to log completion
    const logCompletion = () => {
      if (!logged) {
        const duration = Date.now() - start;
        logger.info(`${method} ${url} - ${res.statusCode} ${duration}ms`);
        logged = true;
      }
    };
    
    // Monkey patch res.end to capture response
    const originalEnd = res.end;
    res.end = function(chunk?: any, encoding?: any) {
      logCompletion();
      return originalEnd.call(this, chunk, encoding);
    };
    
    try {
      await handler(req, res);
    } catch (error) {
      // Ensure we log even if handler throws before res.end
      logCompletion();
      throw error;
    } finally {
      // Final safety net - log if neither path caught it
      logCompletion();
    }
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
      
      // Check if response has already been sent by the handler
      if (res.headersSent) {
        return;
      }
      
      const normalized = normalizer(result);
      res.status(200).json(normalized);
    } catch (err) {
      logger.error('Response normalization error:', err);
      throw err; // Let error handling wrapper handle it
    }
  };
}

// Strict response validation wrapper for critical endpoints
export function withResponseValidation<T>(
  schema: z.ZodSchema<T>,
  handler: (req: VercelRequest, res: VercelResponse) => Promise<T> | T
): Handler {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      const result = await handler(req, res);
      
      // Validate response against schema
      const validation = schema.safeParse(result);
      
      if (!validation.success) {
        // Log validation errors for monitoring
        logger.error('Response validation failed', {
          endpoint: req.url,
          errors: validation.error.errors,
          result: typeof result === 'object' ? JSON.stringify(result, null, 2) : result,
          userId: (req.headers['x-user-id'] as string) || 'anonymous'
        });
        
        // In production, we might want to return the response anyway after logging
        // For now, let's throw to catch schema mismatches in development
        throw new Error(`Response validation failed: ${validation.error.errors.map(e => `${e.path.join('.')}: ${e.message}`).join(', ')}`);
      }
      
      res.status(200).json(validation.data);
    } catch (err) {
      logger.error('Response validation error:', err);
      throw err;
    }
  };
}

export function compose(...wrappers: ((handler: Handler) => Handler)[]): (handler: Handler) => Handler {
  return (handler: Handler): Handler => {
    return wrappers.reduceRight((wrapped, wrapper) => wrapper(wrapped), handler);
  };
}