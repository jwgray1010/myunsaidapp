// api/_lib/http.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { getRequestId } from './logger';

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
  message?: string;
  requestId?: string;
  timestamp: string;
  version: string;
}

// Set standard security headers for all responses
function setSecurityHeaders(res: VercelResponse): void {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
}

export function json<T>(res: VercelResponse, data: T, status = 200, req?: VercelRequest): void {
  const requestId = req ? getRequestId(req) : undefined;
  
  const response: ApiResponse<T> = {
    success: status < 400,
    data: status < 400 ? data : undefined,
    error: status >= 400 ? (typeof data === 'string' ? data : 'An error occurred') : undefined,
    message: status >= 400 ? (typeof data === 'object' && data && 'message' in data ? String(data.message) : undefined) : undefined,
    requestId,
    timestamp: new Date().toISOString(),
    version: 'v1'
  };
  
  // Set security headers
  setSecurityHeaders(res);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  
  // Set request ID header if available
  if (requestId) {
    res.setHeader('X-Request-Id', requestId);
  }
  
  res.status(status).json(response);
}

export function success<T>(res: VercelResponse, data: T, status = 200, req?: VercelRequest): void {
  json(res, data, status, req);
}

export function error(res: VercelResponse, message: string, status = 500, req?: VercelRequest): void {
  json(res, { message }, status, req);
}

export function badRequest(res: VercelResponse, message: string, req?: VercelRequest): void {
  error(res, message, 400, req);
}

export function unauthorized(res: VercelResponse, message = 'Unauthorized', req?: VercelRequest): void {
  error(res, message, 401, req);
}

export function forbidden(res: VercelResponse, message = 'Forbidden', req?: VercelRequest): void {
  error(res, message, 403, req);
}

export function notFound(res: VercelResponse, message = 'Not found', req?: VercelRequest): void {
  error(res, message, 404, req);
}

export function methodNotAllowed(res: VercelResponse, allowed: string[] = [], req?: VercelRequest): void {
  res.setHeader('Allow', allowed.join(', '));
  error(res, `Method not allowed. Allowed methods: ${allowed.join(', ')}`, 405, req);
}

export function tooManyRequests(res: VercelResponse, message = 'Too many requests', req?: VercelRequest): void {
  error(res, message, 429, req);
}

export function internalError(res: VercelResponse, message = 'Internal server error', req?: VercelRequest): void {
  error(res, message, 500, req);
}

// Enhanced body parsing with size limits and better error handling  
export function parseBody<T>(req: VercelRequest, maxSize = 1024 * 1024): Promise<T> {
  return new Promise((resolve, reject) => {
    if (req.method === 'GET' || req.method === 'HEAD') {
      resolve({} as T);
      return;
    }

    // Check if body is already parsed by Vercel
    if (req.body !== undefined) {
      try {
        resolve(req.body as T);
        return;
      } catch (err) {
        reject(new Error('Invalid parsed body'));
        return;
      }
    }

    let body = '';
    let size = 0;
    
    req.on('data', chunk => {
      size += chunk.length;
      if (size > maxSize) {
        reject(new Error(`Request body too large (limit: ${maxSize} bytes)`));
        return;
      }
      body += chunk.toString();
    });

    req.on('end', () => {
      try {
        if (!body.trim()) {
          resolve({} as T);
          return;
        }
        
        const parsed = JSON.parse(body);
        resolve(parsed as T);
      } catch (err) {
        reject(new Error('Invalid JSON in request body'));
      }
    });

    req.on('error', (err) => {
      reject(new Error(`Request error: ${err.message}`));
    });
  });
}

// Validate response data size before sending  
export function validateResponseSize(data: any, maxSize = 10 * 1024 * 1024): void {
  const serialized = JSON.stringify(data);
  if (serialized.length > maxSize) {
    throw new Error(`Response too large (${serialized.length} bytes, limit: ${maxSize})`);
  }
}

// Send response with automatic size validation
export function safeResponse<T>(res: VercelResponse, data: T, status = 200, req?: VercelRequest): void {
  try {
    validateResponseSize(data);
    success(res, data, status, req);
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : 'Response validation failed';
    internalError(res, errorMsg, req);
  }
}