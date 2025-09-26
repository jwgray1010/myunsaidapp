// api/v1/_lib/cloudClient.ts
/**
 * Lightweight HTTP client for calling Google Cloud services
 * This replaces the heavy _lib imports that are now deployed on Google Cloud
 */

import { logger } from './logger';

interface CloudConfig {
  baseUrl: string;
  apiKey?: string;
  timeout: number;
}

class CloudServiceClient {
  private config: CloudConfig;

  constructor() {
    this.config = {
      baseUrl: process.env.GCLOUD_API_URL || 'http://localhost:8080',
      apiKey: process.env.GCLOUD_API_KEY,
      timeout: 30000
    };
  }

  private async makeRequest(endpoint: string, method: 'GET' | 'POST' = 'POST', body?: any) {
    const url = `${this.config.baseUrl}${endpoint}`;
    
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': 'Unsaid-Vercel-Client/1.0'
    };

    if (this.config.apiKey) {
      headers['Authorization'] = `Bearer ${this.config.apiKey}`;
    }

    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), this.config.timeout);

      const response = await fetch(url, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        throw new Error(`Google Cloud API error: ${response.status} ${response.statusText}`);
      }

      return await response.json();
    } catch (error) {
      logger.error('Google Cloud API request failed', { endpoint, error });
      throw error;
    }
  }

  async analyzeTone(params: {
    text: string;
    context?: string;
    attachmentStyle?: string;
    userId?: string;
  }) {
    return this.makeRequest('/tone-analysis', 'POST', params);
  }

  async generateSuggestions(params: {
    text: string;
    toneAnalysis: any;
    context: string;
    attachmentStyle: string;
    userId?: string;
  }) {
    return this.makeRequest('/suggestions', 'POST', params);
  }

  async classifyPersonality(params: {
    text: string;
    userId?: string;
  }) {
    return this.makeRequest('/p-classify', 'POST', params);
  }

  async processCommunicator(params: {
    userId: string;
    action: string;
    data?: any;
  }) {
    return this.makeRequest('/communicator', 'POST', params);
  }

  async healthCheck() {
    return this.makeRequest('/health', 'GET');
  }
}

// Singleton instance
export const cloudClient = new CloudServiceClient();