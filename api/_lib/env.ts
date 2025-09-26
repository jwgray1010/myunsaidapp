// api/_lib/env.ts - Minimal environment configuration for bridges
export const env = {
  NODE_ENV: process.env.NODE_ENV || 'development',
  UNSAID_API_BASE_URL: process.env.UNSAID_API_BASE_URL || '',
  UNSAID_API_KEY: process.env.UNSAID_API_KEY || '',
  GCLOUD_BACKEND_URL: process.env.GCLOUD_BACKEND_URL || 'https://my-node-backend-835271127477.us-central1.run.app',
  CORS_ORIGINS: process.env.CORS_ORIGINS || '*'
};