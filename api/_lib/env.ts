// api/_lib/env.ts
import { z } from 'zod';

// Custom validation helpers
const nonEmptyString = (name: string) => z.string()
  .trim()
  .min(1, `${name} is required and cannot be empty`);

const apiKey = z.string()
  .trim()
  .min(20, 'API keys must be at least 20 characters')
  .max(200, 'API keys cannot exceed 200 characters');

const jwtSecret = z.string()
  .trim()
  .min(32, 'JWT secret must be at least 32 characters for security')
  .max(512, 'JWT secret cannot exceed 512 characters');

const corsOrigins = z.string()
  .trim()
  .default('*')
  .refine((origins) => {
    if (origins === '*') return true;
    
    const originList = origins.split(',').map(o => o.trim()).filter(Boolean);
    return originList.every(origin => {
      try {
        new URL(origin);
        return true;
      } catch {
        return false;
      }
    });
  }, 'CORS origins must be "*" or comma-separated valid URLs');

const envSchema = z.object({
  NODE_ENV: z.string()
    .trim()
    .pipe(z.enum(['development', 'test', 'production']))
    .default('development'),
  
  // Firebase Configuration (optional for now)
  FIREBASE_PROJECT_ID: z.string().trim().optional(),
  FIREBASE_API_KEY: z.string().trim().optional(),
  FIREBASE_AUTH_DOMAIN: z.string().trim().optional(),
  FIREBASE_STORAGE_BUCKET: z.string().trim().optional(),
  FIREBASE_MESSAGING_SENDER_ID: z.string().trim().optional(),
  FIREBASE_APP_ID: z.string().trim().optional(),
  
  // OpenAI Configuration
  OPENAI_API_KEY: z.string()
    .trim()
    .min(1, 'OpenAI API Key is required')
    .refine(key => key.startsWith('sk-') || process.env.NODE_ENV !== 'production',
      'OpenAI API Key must start with "sk-" in production'),
  
  // Security
  JWT_SECRET: jwtSecret.optional(),
  JWT_AUDIENCE: z.string().trim().optional(),
  JWT_ISSUER: z.string().trim().optional(),
  
  // Auth Configuration
  ALLOW_HEADER_AUTH: z.string()
    .trim()
    .transform(val => val === '1' || val.toLowerCase() === 'true')
    .default('false')
    .describe('Allow header-based auth (dev only)'),
  
  // CORS
  CORS_ORIGINS: corsOrigins,
  
  // Rate Limiting
  RATE_LIMIT_WINDOW: z.coerce.number()
    .min(1000, 'Rate limit window must be at least 1 second')
    .max(3600000, 'Rate limit window cannot exceed 1 hour')
    .default(900000), // 15 minutes
  RATE_LIMIT_MAX: z.coerce.number()
    .min(1, 'Rate limit max must be at least 1')
    .max(10000, 'Rate limit max cannot exceed 10,000')
    .default(100),
  
  // Features
  ENABLED_FEATURES: z.string()
    .trim()
    .default('tone,suggestions,advice')
    .refine(features => {
      const featureList = features.split(',').map(f => f.trim());
      const validFeatures = ['tone', 'suggestions', 'advice', 'metrics', 'health'];
      return featureList.every(f => validFeatures.includes(f));
    }, 'Invalid feature in ENABLED_FEATURES'),
  
  // Logging
  LOG_LEVEL: z.string()
    .trim()
    .pipe(z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']))
    .default('info'),
  
  // Service Configuration  
  SERVICE_NAME: z.string().trim().default('unsaid-api'),
  SERVICE_VERSION: z.string().trim().default('1.0.0'),
  
  // Metrics
  METRICS_ENABLED: z.string()
    .trim()
    .transform(val => val !== '0' && val.toLowerCase() !== 'false')
    .default('true'),
}).refine(data => {
  // Production-specific validations
  if (data.NODE_ENV === 'production') {
    if (data.CORS_ORIGINS === '*') {
      throw new z.ZodError([{
        code: z.ZodIssueCode.custom,
        message: 'Wildcard CORS origins (*) not allowed in production',
        path: ['CORS_ORIGINS']
      }]);
    }
    
    if (!data.JWT_SECRET) {
      throw new z.ZodError([{
        code: z.ZodIssueCode.custom,
        message: 'JWT_SECRET is required in production',
        path: ['JWT_SECRET']
      }]);
    }
  }
  
  return true;
}, 'Production environment validation failed');

export type Env = z.infer<typeof envSchema>;

let cachedEnv: Env | null = null;

// Format Zod errors for better readability
function formatValidationError(error: z.ZodError): string {
  const errorMessages = error.errors.map(err => {
    const path = err.path.join('.');
    return `  ${path}: ${err.message}`;
  });
  
  return `Environment validation errors:\n${errorMessages.join('\n')}`;
}

// Validate required production variables early
function validateProductionRequirements(env: Env): void {
  if (env.NODE_ENV === 'production') {
    const issues: string[] = [];
    
    if (env.CORS_ORIGINS === '*') {
      issues.push('CORS_ORIGINS cannot be "*" in production');
    }
    
    if (!env.JWT_SECRET) {
      issues.push('JWT_SECRET is required in production');
    }
    
    if (env.LOG_LEVEL === 'trace' || env.LOG_LEVEL === 'debug') {
      issues.push('LOG_LEVEL should not be "trace" or "debug" in production');
    }
    
    if (issues.length > 0) {
      throw new Error(`Production validation failed:\n${issues.map(i => `  ${i}`).join('\n')}`);
    }
  }
}

export function getEnv(): Env {
  if (cachedEnv) return cachedEnv;
  
  try {
    const rawEnv = { ...process.env };
    const validatedEnv = envSchema.parse(rawEnv);
    
    // Additional production-specific validation
    validateProductionRequirements(validatedEnv);
    
    cachedEnv = validatedEnv;
    
    // Log successful environment loading (only in dev)
    if (validatedEnv.NODE_ENV === 'development' && validatedEnv.LOG_LEVEL === 'debug') {
      console.log('✅ Environment configuration loaded successfully');
    }
    
    return cachedEnv;
  } catch (error) {
    if (error instanceof z.ZodError) {
      const formattedError = formatValidationError(error);
      console.error('❌ Environment validation failed:');
      console.error(formattedError);
      throw new Error(`Invalid environment configuration. Check the console for details.`);
    } else {
      console.error('❌ Environment loading failed:', error);
      throw error;
    }
  }
}

// Validate environment on module load (fail fast)
export const env = getEnv();

// Helper functions for feature flags
export function isFeatureEnabled(feature: string): boolean {
  const features = String(env.ENABLED_FEATURES || '');
  return features.split(',').map((f: string) => f.trim()).includes(feature);
}

// Helper for getting typed environment with runtime checks
export function requireEnvVar(name: keyof Env): string {
  const value = env[name];
  if (value === undefined || value === null || value === '') {
    throw new Error(`Required environment variable ${name} is not set`);
  }
  return String(value);
}