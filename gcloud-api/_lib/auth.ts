// api/_lib/auth.ts
import { Request, Response } from 'express';
import { logger } from './logger';

/**
 * USAGE EXAMPLES:
 * 
 * // Basic auth check (401 if anonymous)
 * export default withAuth(async (req, res, auth) => {
 *   // auth.userId is guaranteed to not be 'anonymous'
 *   return res.json({ userId: auth.userId });
 * });
 * 
 * // Permission check (403 if insufficient permissions)
 * export default withPermission('tone-analysis')(async (req, res, auth) => {
 *   // auth.permissions includes required permission or 'admin'
 *   return res.json({ result: 'allowed' });
 * });
 * 
 * // Combined: Auth only (mass user architecture - no server-side trial checks)
 * export default withAuth(async (req, res, auth) => {
 *   // Device handles subscription/trial checking before API calls
 *   return res.json({ result: 'premium feature' });
 * });
 * 
 * // Or use the combined helper (trial checking disabled for mass users):
 * export default withAuthAndTrialGuard('tone-analysis')(async (req, res, auth) => {
 *   return res.json({ result: 'premium feature' });
 * });
 */

export interface AuthContext {
  userId: string;
  isAuthenticated: boolean;
  userEmail?: string;
  permissions?: string[];
}

/// Extract Bearer token from Authorization header
export function getBearerToken(req: Request): string | null {
  const authHeader = (req.headers.authorization || req.headers.Authorization) as string | undefined;
  if (!authHeader) return null;
  
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  return match?.[1] || null;
}

/// Verify JWT token (stub implementation - JWKS integration later)
export function verifyToken(token: string): AuthContext | null {
  // TODO: Implement proper JWT verification with JWKS
  // For now, return stub data for non-empty tokens
  if (!token) return null;
  
  try {
    // Placeholder: In production, decode and verify JWT properly
    return {
      userId: 'jwt-user-123', // Extract from verified token
      isAuthenticated: true,
      userEmail: 'user@example.com', // Extract from verified token
      permissions: ['basic'] // Extract from verified token
    };
  } catch {
    return null;
  }
}

/// Normalize user ID to handle various input formats and invalid values
function normalizeUserId(v: unknown): string {
  const raw = Array.isArray(v) ? v[0] : v;
  const s = String(raw ?? '').trim();
  const lower = s.toLowerCase();
  if (!s || lower === 'anonymous' || lower === 'null' || lower === 'undefined') {
    return 'anonymous';
  }
  return s; // preserve original case
}

export function extractUserId(req: Request): string {
  // First try Bearer token (production path)
  const bearerToken = getBearerToken(req);
  if (bearerToken) {
    const tokenAuth = verifyToken(bearerToken);
    if (tokenAuth) {
      return tokenAuth.userId;
    }
  }

  // Fallback to header auth only if explicitly allowed (dev mode)
  if (process.env.ALLOW_HEADER_AUTH === '1') {
    return normalizeUserId(
      req.headers['x-user-id'] ??
      req.headers['user-id'] ??
      req.query.userId
      // Removed req.body access to avoid unparsed body issues
    );
  }

  return 'anonymous';
}

export function extractUserEmail(req: Request): string | undefined {
  // First try Bearer token (production path)
  const bearerToken = getBearerToken(req);
  if (bearerToken) {
    const tokenAuth = verifyToken(bearerToken);
    if (tokenAuth) {
      return tokenAuth.userEmail;
    }
  }

  // Fallback to header auth only if explicitly allowed (dev mode)
  if (process.env.ALLOW_HEADER_AUTH === '1') {
    const email = 
      req.headers['x-user-email'] ||
      req.headers['user-email'] ||
      req.query.email;
      // Removed req.body?.email to avoid unparsed body issues
    
    return email as string | undefined;
  }

  return undefined;
}

export function getAuthContext(req: Request): AuthContext {
  // First try Bearer token (production path)
  const bearerToken = getBearerToken(req);
  if (bearerToken) {
    const tokenAuth = verifyToken(bearerToken);
    if (tokenAuth) {
      return tokenAuth;
    }
  }

  // Fallback to header-based auth only if explicitly allowed (dev mode)
  if (process.env.ALLOW_HEADER_AUTH === '1') {
    const userId = extractUserId(req);
    const userEmail = extractUserEmail(req);
    
    const isAuthenticated = userId !== 'anonymous';
    
    return {
      userId,
      isAuthenticated,
      userEmail,
      permissions: isAuthenticated ? ['basic'] : []
    };
  }

  // In production without valid Bearer token, return anonymous
  return {
    userId: 'anonymous',
    isAuthenticated: false,
    userEmail: undefined,
    permissions: []
  };
}

export function requireAuth(req: Request): AuthContext {
  const auth = getAuthContext(req);
  
  if (!auth.isAuthenticated) {
    throw new Error('Authentication required');
  }
  
  return auth;
}

export function requirePermission(req: Request, permission: string): AuthContext {
  const auth = requireAuth(req);
  
  if (!auth.permissions?.includes(permission) && !auth.permissions?.includes('admin')) {
    throw new Error(`Permission required: ${permission}`);
  }
  
  return auth;
}

/// Middleware that returns 401 instead of throwing
export function withAuth(handler: (req: Request, res: Response, auth: AuthContext) => Promise<void>) {
  return async (req: Request, res: Response) => {
    const auth = getAuthContext(req);
    if (!auth.isAuthenticated) {
      res.status(401).json({
        error: 'AUTH_REQUIRED',
        message: 'Authentication required',
        code: 'AUTH_REQUIRED'
      });
      return;
    }
    try {
      await handler(req, res, auth);
    } catch (e) {
      logger.error('Handler error in withAuth', { error: (e as Error).message, userId: auth.userId });
      res.status(500).json({
        error: 'INTERNAL',
        message: 'Internal error', // Don't leak internal error details
        code: 'INTERNAL_ERROR'
      });
    }
  };
}

/// Middleware for permission checking that returns 403 instead of throwing
export function withPermission(permission: string) {
  return (handler: (req: Request, res: Response, auth: AuthContext) => Promise<void>) =>
    withAuth(async (req, res, auth) => {
      const perms = auth.permissions ?? [];
      if (!perms.includes(permission) && !perms.includes('admin')) {
        res.status(403).json({
          error: 'FORBIDDEN',
          message: `Permission required: ${permission}`,
          code: 'PERMISSION_DENIED',
          requiredPermission: permission,
          userPermissions: perms
        });
        return;
      }
      await handler(req, res, auth);
    });
}

/// Combined middleware: Auth only (DISABLED trial guard for mass user architecture)
/// For mass users, subscription/trial checking is now handled on device
export function withAuthAndTrialGuard(permission?: string, trialConfig?: any) {
  return (handler: (req: Request, res: Response, auth: AuthContext) => Promise<void>) => {
    // Mass user architecture: Only check auth, no server-side trial checking
    // Subscription/trial status is checked on device before API calls
    const authMiddleware = permission ? withPermission(permission) : withAuth;
    
    // Skip trial middleware - device handles subscription access control
    return authMiddleware(handler);
  };
}