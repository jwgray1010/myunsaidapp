// api/v1/_lib/http.ts
/**
 * Lightweight HTTP utilities for Vercel v1 endpoints
 */

import { VercelResponse } from '@vercel/node';

export function success(res: VercelResponse, data: any, status: number = 200) {
  return res.status(status).json({
    success: true,
    data,
    timestamp: new Date().toISOString()
  });
}

export function error(res: VercelResponse, message: string, status: number = 400, details?: any) {
  return res.status(status).json({
    success: false,
    error: message,
    details,
    timestamp: new Date().toISOString()
  });
}