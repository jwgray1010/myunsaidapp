// api/v1/health.ts - Bridge health check (Google Cloud proxy status)
import { VercelRequest, VercelResponse } from '@vercel/node';
import { logger } from '../_lib/logger';

// Timeout wrapper with actual cancellation (prevents socket pile-up)
function callWithTimeout<T>(
  promiseFactory: (signal: AbortSignal) => Promise<T>, 
  timeoutMs: number = 5000
): Promise<T> {
  const controller = new AbortController();
  
  return Promise.race([
    promiseFactory(controller.signal),
    new Promise<T>((_, reject) => {
      setTimeout(() => {
        controller.abort(); // Actually cancel the request
        reject(Object.assign(new Error('Timeout'), { name: 'AbortError' }));
      }, timeoutMs);
    })
  ]);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  // CORS + Cache control (prevent edge/CDN caching of health responses)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Cache-Control', 'no-store'); // Prevent caching of health responses
  
  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }
  
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }
  
  const startTime = Date.now();
  const requestId = Math.random().toString(36).substring(2, 15);
  
  logger.info(`[${requestId}] Health check initiated`);
  
  try {
    // Check Google Cloud backend connectivity (dynamic import to avoid cold-start cost)
    let gcloudStatus = { connected: false, latency: 0, error: null as string | null };
    
    try {
      const gcloudStart = Date.now();
      
      // Dynamic import to avoid cold-start inheritance
      const { gcloudClient } = await import('../_lib/gcloudClient');
      
      await callWithTimeout(
        (signal) => {
          // Note: gcloudClient.checkHealth() doesn't support AbortSignal yet
          // But the timeout will still cancel the Promise.race
          return gcloudClient.checkHealth();
        }, 
        5000
      );
      
      gcloudStatus = {
        connected: true,
        latency: Date.now() - gcloudStart,
        error: null
      };
    } catch (error) {
      gcloudStatus = {
        connected: false,
        latency: 0,
        error: error instanceof Error ? error.message : 'Unknown error'
      };
    }
    
    // Basic runtime info
    const runtime = {
      node_version: process.version,
      memory: process.memoryUsage(),
      uptime: process.uptime()
    };
    
    // Determine overall health - decouple from backend readiness to prevent monitor flapping
    const healthScore = gcloudStatus.connected ? 100 : 80; // Still functional without backend
    const status = gcloudStatus.connected ? 'healthy' : 'degraded'; // Don't mark as unhealthy
    
    const processingTime = Date.now() - startTime;
    
    logger.info(`[${requestId}] Health check completed: ${status} (${healthScore}/100)`);
    
    // Always return 200 - let monitors check the status field instead of HTTP code
    return res.status(200).json({
      status,
      score: healthScore,
      timestamp: new Date().toISOString(),
      bridge: {
        type: 'vercel_to_gcloud',
        backend_connected: gcloudStatus.connected,
        backend_latency_ms: gcloudStatus.latency,
        backend_error: gcloudStatus.error
      },
      runtime,
      metadata: {
        processingTimeMs: processingTime,
        version: 'bridge-v1.0.0',
        request_id: requestId
      }
    });
  } catch (error) {
    logger.error(`[${requestId}] Health check failed:`, error);
    
    return res.status(500).json({
      status: 'error',
      error: 'Health check failed',
      details: error instanceof Error ? error.message : 'Unknown error',
      timestamp: new Date().toISOString()
    });
  }
}