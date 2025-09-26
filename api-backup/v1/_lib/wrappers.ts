// api/v1/_lib/wrappers.ts
/**
 * Lightweight wrappers for Vercel v1 endpoints
 * Simplified versions without heavy dependencies
 */

import { VercelRequest, VercelResponse } from '@vercel/node';
import { logger } from './logger';
import { error } from './http';

export function withCors(handler: Function) {
  return async (req: VercelRequest, res: VercelResponse) => {
    // Set CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-User-ID');
    
    if (req.method === 'OPTIONS') {
      return res.status(200).end();
    }
    
    return handler(req, res);
  };
}

export function withMethods(methods: string[]) {
  return (handler: Function) => {
    return async (req: VercelRequest, res: VercelResponse) => {
      if (!methods.includes(req.method || '')) {
        return error(res, `Method ${req.method} not allowed`, 405);
      }
      return handler(req, res);
    };
  };
}

export function withErrorHandling(handler: Function) {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      return await handler(req, res);
    } catch (err) {
      logger.error('Request handler error', { error: err });
      return error(res, 'Internal server error', 500);
    }
  };
}

export function withLogging(handler: Function) {
  return async (req: VercelRequest, res: VercelResponse) => {
    const start = Date.now();
    logger.info(`${req.method} ${req.url}`);
    
    try {
      const result = await handler(req, res);
      logger.info(`${req.method} ${req.url} - ${Date.now() - start}ms`);
      return result;
    } catch (err) {
      logger.error(`${req.method} ${req.url} - ${Date.now() - start}ms - ERROR`, { error: err });
      throw err;
    }
  };
}

export function withValidation(schema?: any) {
  return (handler: Function) => {
    return async (req: VercelRequest, res: VercelResponse) => {
      // Simplified validation - just check for required body on POST
      if (req.method === 'POST' && !req.body) {
        return error(res, 'Request body required', 400);
      }
      return handler(req, res);
    };
  };
}

export function withResponseNormalization(handler: Function) {
  return handler; // Pass-through for now
}