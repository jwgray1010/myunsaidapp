import type { Request, Response } from 'express';
import { getPrometheusMetrics, getPrometheusContentType } from './_lib/metrics';

export default function handler(req: Request, res: Response) {
  // Only allow GET requests
  if (req.method !== 'GET') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const metricsOutput = getPrometheusMetrics();
    
    res.setHeader('Content-Type', getPrometheusContentType());
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.status(200).send(metricsOutput);
  } catch (error) {
    console.error('Error generating metrics:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}