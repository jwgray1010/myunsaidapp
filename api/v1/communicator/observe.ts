// /api/v1/communicator/observe.ts
import type { VercelRequest, VercelResponse } from '@vercel/node';

// Simple proxy to the main communicator handler's observe function
// This ensures /api/v1/communicator/observe works correctly with Vercel routing
export default async function handler(req: VercelRequest, res: VercelResponse) {
  // Import the main communicator handler
  const communicatorHandler = await import('../communicator');
  
  // Modify the request URL to make it look like /observe for the main handler
  if (req.url) {
    req.url = req.url.replace(/.*\/observe/, '/observe');
  }
  
  // Forward to the main communicator handler
  return communicatorHandler.default(req, res);
}