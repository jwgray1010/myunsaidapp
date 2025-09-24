// apps/web/api/v1/tone.ts - Bridge to Cloud Run inference service
import { VercelRequest, VercelResponse } from '@vercel/node';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  // Only allow POST requests
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const body = req.body;
    if (!body || !body.text) {
      return res.status(400).json({ error: 'text field required' });
    }

    // Bridge to Cloud Run inference service
    const inferenceUrl = process.env.INF_BASE_URL;
    const authToken = process.env.INF_TOKEN;

    if (!inferenceUrl) {
      return res.status(500).json({ error: 'Inference service not configured' });
    }

    const response = await fetch(`${inferenceUrl}/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(authToken && { 'Authorization': `Bearer ${authToken}` })
      },
      body: JSON.stringify(body),
    });

    const data = await response.json();

    return res.status(response.status).json(data);
  } catch (error) {
    console.error('Bridge error:', error);
    return res.status(500).json({
      error: 'inference_failed',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
}
