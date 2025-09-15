// api/_lib/auth.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
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
 * // Combined: Auth + Trial Guard (recommended)
 * import { withTrialGuard } from './middleware/trialGuard';
 * export default withAuth(withTrialGuard({ feature: 'tone-analysis' })(async (req, res, auth) => {
 *   // 401 if anonymous, 402 if trial expired, 200 if allowed
 *   return res.json({ result: 'premium feature' });
 * }));
 * 
 * // Or use the combined helper:
 * export default withAuthAndTrialGuard('tone-analysis', { feature: 'tone-analysis' })(async (req, res, auth) => {
 *   return res.json({ result: 'premium feature' });
 * });
 */

export interface AuthContext {
  userId: string;
  isAuthenticated: boolean;
  userEmail?: string;
  permissions?: string[];
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

export function extractUserId(req: VercelRequest): string {
  return normalizeUserId(
    req.headers['x-user-id'] ??
    req.headers['user-id'] ??
    req.query.userId ??
    (req.body && (req.body as any).userId)
  );
}

export function extractUserEmail(req: VercelRequest): string | undefined {
  const email = 
    req.headers['x-user-email'] ||
    req.headers['user-email'] ||
    req.query.email ||
    req.body?.email;
    
  return email as string | undefined;
}

export function getAuthContext(req: VercelRequest): AuthContext {
  const userId = extractUserId(req);
  const userEmail = extractUserEmail(req);
  
  // In a real implementation, you would validate JWT tokens here
  const isAuthenticated = userId !== 'anonymous';
  
  return {
    userId,
    isAuthenticated,
    userEmail,
    permissions: isAuthenticated ? ['basic'] : []
  };
}

export function requireAuth(req: VercelRequest): AuthContext {
  const auth = getAuthContext(req);
  
  if (!auth.isAuthenticated) {
    throw new Error('Authentication required');
  }
  
  return auth;
}

export function requirePermission(req: VercelRequest, permission: string): AuthContext {
  const auth = requireAuth(req);
  
  if (!auth.permissions?.includes(permission) && !auth.permissions?.includes('admin')) {
    throw new Error(`Permission required: ${permission}`);
  }
  
  return auth;
}

/// Middleware that returns 401 instead of throwing
export function withAuth(handler: (req: VercelRequest, res: VercelResponse, auth: AuthContext) => Promise<void>) {
  return async (req: VercelRequest, res: VercelResponse) => {
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
        message: (e as Error).message,
        code: 'INTERNAL_ERROR'
      });
    }
  };
}

/// Middleware for permission checking that returns 403 instead of throwing
export function withPermission(permission: string) {
  return (handler: (req: VercelRequest, res: VercelResponse, auth: AuthContext) => Promise<void>) =>
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

/// Combined middleware: Auth + Trial Guard (recommended order)
export function withAuthAndTrialGuard(permission?: string, trialConfig?: any) {
  return (handler: (req: VercelRequest, res: VercelResponse, auth: AuthContext) => Promise<void>) => {
    // First check auth (401 if anonymous)
    const authMiddleware = permission ? withPermission(permission) : withAuth;
    
    // Then check trial/payment (402 if expired)
    const trialMiddleware = trialConfig ? 
      require('./middleware/trialGuard').withTrialGuard(trialConfig) : 
      (h: any) => h;
    
    return authMiddleware(trialMiddleware(handler));
  };
}