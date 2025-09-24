// api/_lib/cors.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { env } from './env';

function parseOrigins(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return ['*'];
  return raw.split(',').map(o => o.trim()).filter(Boolean);
}

export function setCorsHeaders(req: VercelRequest, res: VercelResponse): void {
  const origin = (req.headers.origin as string | undefined) || '';
  const requestMethod = (req.headers['access-control-request-method'] as string | undefined) || '';
  const requestHeaders = (req.headers['access-control-request-headers'] as string | undefined) || '';

  const allowedOrigins = parseOrigins(env.CORS_ORIGINS);
  const allowsAny = allowedOrigins.includes('*');
  const isAllowedOrigin = origin && (allowsAny || allowedOrigins.includes(origin));

  // Always set Vary when behavior depends on request headers
  // Helps caches avoid serving the wrong CORS headers
  res.setHeader('Vary', 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers');

  // Origin handling:
  // - If we have an Origin and it's allowed, echo it (works with credentials)
  // - Else if wildcard configured but no origin, allow '*' without credentials
  if (isAllowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    // Only send credentials when echoing a specific origin (never with '*')
    res.setHeader('Access-Control-Allow-Credentials', 'true');
  } else if (allowsAny) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    // Do NOT set Allow-Credentials with '*'
  }

  // Methods: reflect requested method on preflight, otherwise provide a sane list
  const allowMethods = requestMethod
    ? requestMethod
    : 'GET, POST, PUT, PATCH, DELETE, OPTIONS';

  res.setHeader('Access-Control-Allow-Methods', allowMethods);

  // Headers: reflect requested headers on preflight; otherwise allow common set
  const allowHeaders = requestHeaders
    ? requestHeaders
    : 'Content-Type, Authorization, X-Requested-With';

  res.setHeader('Access-Control-Allow-Headers', allowHeaders);

  // Cache preflight for a day (browsers may cap this)
  res.setHeader('Access-Control-Max-Age', '86400');
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
