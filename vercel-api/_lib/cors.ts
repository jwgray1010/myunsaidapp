// api/_lib/cors.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { env } from './env';
import { getRequestId } from './logger';

// Default allowed headers (restrictive by default, expandable via env)
const DEFAULT_ALLOWED_HEADERS = [
  'Content-Type',
  'Authorization', 
  'X-Requested-With',
  'X-Request-Id',
  'X-API-Key',
  'Accept',
  'Accept-Encoding',
  'Cache-Control'
];

// Default allowed methods
const DEFAULT_ALLOWED_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];

function parseOrigins(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return ['*'];
  return raw.split(',').map(o => o.trim()).filter(Boolean);
}

function parseHeaders(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return DEFAULT_ALLOWED_HEADERS;
  return raw.split(',').map(h => h.trim()).filter(Boolean);
}

function parseMethods(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return DEFAULT_ALLOWED_METHODS;
  return raw.split(',').map(m => m.trim().toUpperCase()).filter(Boolean);
}

// Validate origin against stricter patterns
function isValidOrigin(origin: string): boolean {
  if (!origin) return false;
  
  try {
    const url = new URL(origin);
    
    // Block dangerous schemes
    if (!['http:', 'https:'].includes(url.protocol)) {
      return false;
    }
    
    // Block localhost in production (can be overridden via explicit origin list)
    if (env.NODE_ENV === 'production') {
      const hostname = url.hostname.toLowerCase();
      if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname.endsWith('.local')) {
        return false; // Blocked in production unless explicitly in CORS_ORIGINS
      }
    }
    
    return true;
  } catch {
    return false;
  }
}

export function setCorsHeaders(req: VercelRequest, res: VercelResponse): void {
  const origin = (req.headers.origin as string | undefined) || '';
  const requestMethod = (req.headers['access-control-request-method'] as string | undefined) || '';
  const requestHeaders = (req.headers['access-control-request-headers'] as string | undefined) || '';
  const requestId = getRequestId(req);

  const allowedOrigins = parseOrigins(env.CORS_ORIGINS);
  const allowedHeaders = parseHeaders(process.env.CORS_HEADERS);
  const allowedMethods = parseMethods(process.env.CORS_METHODS);
  
  const allowsAny = allowedOrigins.includes('*');
  const isValidOriginFormat = isValidOrigin(origin);
  const isAllowedOrigin = origin && isValidOriginFormat && (allowsAny || allowedOrigins.includes(origin));

  // Always set Vary when behavior depends on request headers
  // Helps caches avoid serving the wrong CORS headers
  res.setHeader('Vary', 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers');

  // Set request ID header for tracing
  res.setHeader('X-Request-Id', requestId);

  // Origin handling:
  // - If we have an Origin and it's allowed, echo it (works with credentials)
  // - Else if wildcard configured but no origin, allow '*' without credentials
  if (isAllowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    // Only send credentials when echoing a specific origin (never with '*')
    res.setHeader('Access-Control-Allow-Credentials', 'true');
  } else if (allowsAny && (!origin || isValidOriginFormat)) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    // Do NOT set Allow-Credentials with '*'
  }

  // Methods: use configured list, or reflect requested method on preflight
  const allowMethods = requestMethod && allowedMethods.includes(requestMethod.toUpperCase())
    ? requestMethod
    : allowedMethods.join(', ');

  res.setHeader('Access-Control-Allow-Methods', allowMethods);

  // Headers: use configured list, validate requested headers against allowlist
  let allowHeaders: string;
  if (requestHeaders) {
    const requested = requestHeaders.split(',').map(h => h.trim());
    const filtered = requested.filter(h => 
      allowedHeaders.some(allowed => allowed.toLowerCase() === h.toLowerCase())
    );
    allowHeaders = filtered.length > 0 ? filtered.join(', ') : allowedHeaders.join(', ');
  } else {
    allowHeaders = allowedHeaders.join(', ');
  }

  res.setHeader('Access-Control-Allow-Headers', allowHeaders);

  // Cache preflight for shorter time in production for security
  const maxAge = env.NODE_ENV === 'production' ? '3600' : '86400'; // 1 hour in prod, 1 day in dev
  res.setHeader('Access-Control-Max-Age', maxAge);

  // Additional security headers
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
}

export function handleCors(req: VercelRequest, res: VercelResponse): boolean {
  setCorsHeaders(req, res);

  // Handle preflight early
  if (req.method === 'OPTIONS') {
    // No body on preflight
    res.status(204).end();
    return true;
  }

  return false; // Continue to the route handler
}
