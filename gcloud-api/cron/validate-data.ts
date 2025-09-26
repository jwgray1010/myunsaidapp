// api/cron/validate-data.ts
import { Request, Response } from 'express';
import { withMethods, withErrorHandling, withLogging } from '../_lib/wrappers';
import { success, error as httpError } from '../_lib/http';
import { logger } from '../_lib/logger';

function isAuthorizedCron(req: Request): boolean {
  const token = (req.query?.auth_token || req.query?.token || '').toString();
  const expected = process.env.CRON_TOKEN || 'f47ac10b-58cc-4372-a567-0e02b2c3d479';
  return Boolean(expected) && token === expected;
}

const handler = async (req: Request, res: Response) => {
  if (!isAuthorizedCron(req)) {
    return httpError(res, 'Unauthorized cron', 401);
  }

  const startTime = Date.now();

  try {
    logger.info('Starting health check via existing /api/v1/health endpoint');

    // Determine base URL
    const baseUrl = process.env.VERCEL_URL 
      ? `https://${process.env.VERCEL_URL}`
      : req.headers.host 
        ? `https://${req.headers.host}`
        : 'https://api.myunsaidapp.com';

    // Call the existing health endpoint with detailed status
    const healthUrl = `${baseUrl}/api/v1/health?check=status`;
    
    const response = await fetch(healthUrl, {
      headers: {
        'User-Agent': 'Unsaid-DataValidation-Cron/1.0'
      }
    });

    const healthData = await response.json();
    const duration = Date.now() - startTime;

    if (response.ok && (healthData as any).ok) {
      logger.info('Health check passed', {
        duration,
        healthyChecks: (healthData as any).checks?.filter((c: any) => c.ok).length || 0,
        failedChecks: (healthData as any).failing?.length || 0
      });

      return success(
        res,
        {
          success: true,
          data: {
            health: healthData,
            cron: {
              duration,
              timestamp: new Date().toISOString(),
              baseUrl,
              status: 'healthy'
            }
          },
          meta: {
            version: '2.0.0',
            type: 'health-proxy'
          }
        },
        200
      );
    } else {
      logger.warn('Health check failed', {
        duration,
        status: response.status,
        failing: (healthData as any).failing
      });

      return success(
        res,
        {
          success: false,
          data: {
            health: healthData,
            cron: {
              duration,
              timestamp: new Date().toISOString(),
              baseUrl,
              status: 'unhealthy'
            }
          },
          meta: {
            version: '2.0.0',
            type: 'health-proxy'
          }
        },
        response.status
      );
    }
  } catch (error: any) {
    const duration = Date.now() - startTime;
    logger.error('Health check cron job failed:', error);
    
    return httpError(res, `Health check failed: ${error.message}`, 503);
  }
};

export default withErrorHandling(
  withLogging(
    withMethods(['GET'], handler)
  )
);