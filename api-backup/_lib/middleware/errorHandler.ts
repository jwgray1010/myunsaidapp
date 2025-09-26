// api/_lib/middleware/errorHandler.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { ZodError } from 'zod';
import { logger } from '../logger';
import { env } from '../env';

// Custom Error Classes
export class AppError extends Error {
  public readonly statusCode: number;
  public readonly code: string;
  public readonly isOperational: boolean;

  constructor(message: string, statusCode: number = 500, code: string = 'ERR_UNKNOWN', isOperational: boolean = true) {
    super(message);
    this.name = this.constructor.name;
    this.statusCode = statusCode;
    this.code = code;
    this.isOperational = isOperational;

    Error.captureStackTrace(this, this.constructor);
  }
}

export class AppValidationError extends AppError {
  public readonly details?: any;

  constructor(message: string = 'Validation failed', details?: any) {
    super(message, 400, 'ERR_VALIDATION');
    this.details = details;
  }
}

export class AppNotFoundError extends AppError {
  constructor(message: string = 'Resource not found') {
    super(message, 404, 'ERR_NOT_FOUND');
  }
}

export class AppUnauthorizedError extends AppError {
  constructor(message: string = 'Unauthorized access') {
    super(message, 401, 'ERR_UNAUTHORIZED');
  }
}

export class AppForbiddenError extends AppError {
  constructor(message: string = 'Access forbidden') {
    super(message, 403, 'ERR_FORBIDDEN');
  }
}

export class AppTooManyRequestsError extends AppError {
  constructor(message: string = 'Too many requests') {
    super(message, 429, 'ERR_TOO_MANY_REQUESTS');
  }
}

// Zod error formatter with duck-typing support
function isZodErrorLike(err: any): err is ZodError {
  return !!err && typeof err === 'object' && Array.isArray((err as any).issues || (err as any).errors) &&
         (err.name === 'ZodError' || typeof (err as any).flatten === 'function');
}

function formatZodError(error: ZodError): { message: string; details: any[] } {
  const details = (error.errors || (error as any).issues || []).map((err: any) => ({
    field: Array.isArray(err.path) ? err.path.join('.') : '',
    message: err.message,
    code: err.code,
    received: err.code === 'invalid_type' ? (err as any).received : undefined,
  }));
  return { message: 'Validation failed', details };
}

// Main error handler with enhanced safety features
export function handleError(err: any, req: VercelRequest, res: VercelResponse): void {
  // If response already started, just log and end safely
  if (res.headersSent) {
    logger.error('Error after headers sent', { url: req.url, method: req.method, err: serializeError(err) });
    try { res.end(); } catch {}
    return;
  }

  // Request id
  const reqId =
    (req as any).id ||
    (req.headers['x-request-id'] as string) ||
    `req_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;

  res.setHeader('X-Request-Id', reqId);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');

  const baseResponse = { success: false, reqId, timestamp: new Date().toISOString() };

  let statusCode = 500;
  let responsePayload: any = { ...baseResponse, error: 'Internal Server Error', code: 'ERR_INTERNAL' };

  // Normalize non-Error throws
  if (!(err instanceof Error)) {
    err = new Error(typeof err === 'string' ? err : 'Non-Error thrown');
  }

  // Handle different error types
  if (err instanceof AppError) {
    // Custom application errors
    statusCode = err.statusCode;
    responsePayload = { ...baseResponse, error: err.message, code: err.code };
    if (err instanceof AppValidationError && (err as AppValidationError).details) {
      responsePayload.details = (err as AppValidationError).details;
    }

  // Zod (support instanceof OR duck-type)
  } else if (err instanceof ZodError || isZodErrorLike(err)) {
    statusCode = 400;
    const formatted = formatZodError(err as ZodError);
    responsePayload = { ...baseResponse, error: formatted.message, code: 'ERR_VALIDATION', details: formatted.details };

  // Generic validation
  } else if ((err as any).name === 'ValidationError') {
    statusCode = 400;
    responsePayload = { ...baseResponse, error: err.message || 'Validation failed', code: 'ERR_VALIDATION' };

  // Auth/JWT
  } else if ((err as any).name === 'JsonWebTokenError') {
    statusCode = 401;
    responsePayload = { ...baseResponse, error: 'Invalid authentication token', code: 'ERR_INVALID_TOKEN' };
  } else if ((err as any).name === 'TokenExpiredError') {
    statusCode = 401;
    responsePayload = { ...baseResponse, error: 'Authentication token expired', code: 'ERR_TOKEN_EXPIRED' };

  // Network/infra / timeouts
  } else if (['ENOTFOUND','ECONNREFUSED','ETIMEDOUT','EAI_AGAIN'].includes((err as any).code)) {
    statusCode = 503;
    responsePayload = { ...baseResponse, error: 'Service temporarily unavailable', code: 'ERR_SERVICE_UNAVAILABLE' };
  } else if ((err as any).name === 'AbortError' /* node-fetch */) {
    statusCode = 503;
    responsePayload = { ...baseResponse, error: 'Upstream request aborted', code: 'ERR_SERVICE_UNAVAILABLE' };
  }

  // Forward Retry-After if upstream provided (rate limits)
  const retryAfter = (err as any)?.retryAfter || (err as any)?.headers?.['retry-after'];
  if (retryAfter && String(retryAfter)) {
    res.setHeader('Retry-After', String(retryAfter));
  }

  // Include stack only in dev
  if (env.NODE_ENV !== 'production' && err.stack) {
    responsePayload.stack = err.stack.split('\n').slice(0, 20); // cap length
    if ((err as any).cause instanceof Error) {
      responsePayload.cause = {
        name: (err as any).cause.name,
        message: (err as any).cause.message,
        stack: ((err as any).cause.stack || '').split('\n').slice(0, 10),
      };
    }
  }

  // Log
  const logContext = {
    reqId,
    method: req.method,
    url: req.url,
    status: statusCode,
    code: responsePayload.code,
    userAgent: req.headers['user-agent'],
    ip: req.headers['x-forwarded-for'] || req.headers['x-real-ip'] || 'unknown',
    error: serializeError(err),
  };

  if (statusCode >= 500) logger.error('Server error occurred', logContext);
  else if (statusCode >= 400) logger.warn('Client error occurred', logContext);
  else logger.info('Handled error', logContext);

  // Check if headers have already been sent to prevent "Cannot set headers after they are sent" error
  if (res.headersSent) {
    logger.error('Error after headers sent', {
      url: req.url,
      method: req.method,
      err: serializeError(err)
    });
    return;
  }

  res.status(statusCode).json(responsePayload);
}

function serializeError(e: any) {
  if (!e) return { name: 'UnknownError', message: 'Unknown' };
  return {
    name: e.name || 'Error',
    message: e.message || String(e),
    code: (e as any).code,
    stack: e.stack ? e.stack.split('\n').slice(0, 5) : undefined,
  };
}

// Error wrapper for async functions (rethrows - callers must handle)
export function withErrorHandling<T extends any[], R>(
  fn: (...args: T) => Promise<R>
): (...args: T) => Promise<R | void> {
  return async (...args: T): Promise<R | void> => {
    try {
      return await fn(...args);
    } catch (error) {
      // Deliberately rethrow; callers using this variant must handle (e.g., withErrorMiddleware)
      throw error;
    }
  };
}

// Middleware wrapper that includes error handling
export function withErrorMiddleware(
  handler: (req: VercelRequest, res: VercelResponse) => Promise<void>
) {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      await handler(req, res);
    } catch (error) {
      handleError(error, req, res);
    }
  };
}