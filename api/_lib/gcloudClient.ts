// api/_lib/gcloudClient.ts
import { logger } from './logger';

export interface GCloudToneRequest {
  text: string;
  context?: string;
  attachmentStyle?: string;
  deepAnalysis?: boolean;
  isNewUser?: boolean;
  rich?: any;  // v1.5 rich context for deeper analysis
  mode?: string;  // iOS coordinator mode field
  doc_seq?: number;  // iOS coordinator document sequence
  text_hash?: string;  // iOS coordinator text hash
  client_seq?: number;  // iOS coordinator client sequence
  toneAnalysis?: any;  // Forward any existing tone analysis
  userProfile?: {
    id: string;
    attachment?: string;
    secondary?: string;
    windowComplete?: boolean;
  };
}

export interface GCloudSuggestionsRequest {
  text: string;
  toneAnalysis?: any; // Consistent tone analysis field
  context?: string;
  attachmentStyle?: string;
  rich?: any;   // v1.5 rich context (contextClassifier, attachmentBoosts, etc)
  meta?: any;   // v1.5 metadata (locale, tz, client info)
  compose_id?: string;  // Session correlation ID
}

export interface GCloudResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
  requestId?: string;
  timestamp: string;
  version: string;
}

class GoogleCloudClient {
  private readonly baseUrl: string;
  private readonly timeout: number;

  constructor() {
    this.baseUrl = process.env.GCLOUD_API_URL || 'https://unsaid-gcloud-api-835271127477.us-central1.run.app';
    this.timeout = 30000; // 30 seconds
  }

  private async makeRequest<T>(
    endpoint: string, 
    data: any, 
    options: RequestInit = {}
  ): Promise<T> {
    const url = `${this.baseUrl}${endpoint}`;
    const requestId = `req_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

    try {
      logger.info('🌐 Google Cloud API request', { 
        url, 
        requestId,
        dataSize: JSON.stringify(data).length 
      });

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), this.timeout);

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Unsaid-Vercel-Proxy/1.0',
          'X-Request-ID': requestId,
          ...options.headers
        },
        body: JSON.stringify(data),
        signal: controller.signal,
        ...options
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Google Cloud API error: ${response.status} ${response.statusText} - ${errorText}`);
      }

      const result = await response.json() as GCloudResponse<T>;
      
      if (!result.success) {
        throw new Error(`Google Cloud service error: ${result.error || 'Unknown error'}`);
      }

      logger.info('✅ Google Cloud API success', { 
        requestId, 
        responseTime: `${Date.now() - parseInt(requestId.split('_')[1])}ms` 
      });

      return result.data!;

    } catch (error) {
      logger.error('❌ Google Cloud API error', { 
        url, 
        requestId, 
        error: error instanceof Error ? error.message : String(error) 
      });
      
      // Re-throw with context
      throw new Error(`Google Cloud backend error: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  /**
   * Call Google Cloud backend for heavy tone analysis
   */
  async analyzeTone(request: GCloudToneRequest): Promise<any> {
    return this.makeRequest('/tone-analysis', request);
  }

  /**
   * Call Google Cloud backend for advanced suggestions
   */
  async generateSuggestions(request: GCloudSuggestionsRequest): Promise<any> {
    return this.makeRequest('/suggestions', request);
  }

  /**
   * Health check for Google Cloud backend
   */
  async healthCheck(): Promise<{ status: string; service: string; timestamp: string; version: string }> {
    try {
      const response = await fetch(`${this.baseUrl}/health`, {
        method: 'GET',
        headers: {
          'User-Agent': 'Unsaid-Vercel-Health/1.0'
        }
      });

      if (!response.ok) {
        throw new Error(`Health check failed: ${response.status} ${response.statusText}`);
      }

      return await response.json() as { status: string; service: string; timestamp: string; version: string };
    } catch (error) {
      logger.error('Google Cloud health check failed', { error });
      throw error;
    }
  }

  /**
   * Alias for backward compatibility
   */
  async checkHealth(): Promise<{ status: string; service: string; timestamp: string; version: string }> {
    return this.healthCheck();
  }
}

// Singleton instance
export const gcloudClient = new GoogleCloudClient();

// Helper function to check if Google Cloud backend should be used
export function shouldUseGoogleCloud(text: string, options: any = {}): boolean {
  // Use Google Cloud for:
  // 1. Long text (>500 chars) for better ML processing
  // 2. Deep analysis requests
  // 3. Complex attachment style analysis
  // 4. P-code classification
  
  const textLength = text.length;
  const isDeepAnalysis = options.deepAnalysis === true;
  const hasComplexProfile = options.userProfile && options.userProfile.attachment;
  const isFullMode = options.isFullMode === true;

  return textLength > 500 || isDeepAnalysis || hasComplexProfile || isFullMode;
}

// Fallback configuration
export const GCLOUD_CONFIG = {
  enabled: true, // Set to false to disable Google Cloud integration
  maxRetries: 2,
  retryDelay: 1000, // 1 second
  healthCheckInterval: 300000, // 5 minutes
} as const;