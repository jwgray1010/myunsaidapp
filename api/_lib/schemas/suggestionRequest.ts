// api/_lib/schemas/suggestionRequest.ts
import { z } from 'zod';

/**
 * Enhanced SuggestionRequest schema matching the JSON schema structure
 * Schema for generating therapy advice and communication guidance
 * Version: 1.0.0 - Last Updated: 2025-08-28
 */

// Tone override enum (matching JSON schema)
export const toneOverrideSchema = z.enum(['alert', 'caution', 'clear']).describe('Optional override for detected tone');

// Attachment style enum (matching JSON schema)
export const attachmentStyleSchema = z.enum(['anxious', 'avoidant', 'disorganized', 'secure']).describe('User attachment style');

// Features array for response customization
export const featuresSchema = z.array(z.enum(['advice', 'quick_fixes', 'evidence', 'emotional_support', 'context_analysis'])).max(8).optional().describe('Feature flags to include in the response');

// Meta object for tracing and UX decisions
export const metaSchema = z.object({
  platform: z.string().optional().describe('Platform identifier (e.g., ios_keyboard)'),
  timestamp: z.string().datetime().optional().describe('Request timestamp'),
  user: z.string().optional().describe('User identifier'),
  locale: z.string().optional().describe('User locale (e.g., en-US)'),
  sessionId: z.string().optional().describe('Session identifier for tracking'),
  requestId: z.string().optional().describe('Unique request identifier'),
  relationshipStage: z.string().optional().describe('Current relationship stage'),
  conflictLevel: z.enum(['low', 'medium', 'high']).optional().describe('Current conflict level'),
}).passthrough().describe('Optional metadata for tracing and UX decisions');

// Main SuggestionRequest schema (matching JSON schema structure)
export const suggestionRequestSchema = z.object({
  text: z.string()
    .min(1, 'A valid message text (1–5000 characters) is required')
    .max(5000, 'A valid message text (1–5000 characters) is required')
    .describe('The message to analyze and provide therapy advice for'),
  context: z.string().optional().describe('Optional hint about conversation context - system auto-detects from text if not provided'),
  toneOverride: toneOverrideSchema.optional().describe('Optional override for detected tone. Useful for testing or manual control'),
  attachmentStyle: attachmentStyleSchema.optional().describe('Optional user attachment-style override, if already known'),
  features: featuresSchema.optional().describe('Feature flags to include in the response. Common values: advice, quick_fixes, evidence, emotional_support'),
  meta: metaSchema.optional().describe('Optional metadata for tracing and UX decisions'),
  // Client sequencing fields (used by coordinators)
  client_seq: z.number().optional().describe('Client sequence number for last-writer-wins'),
  clientSeq: z.number().optional().describe('Alternative client sequence number field'),
  requestId: z.string().optional().describe('Unique request identifier for tracing'),
});

export type SuggestionRequest = z.infer<typeof suggestionRequestSchema>;

/** SUGGESTION ITEM — accept backend fields too */
export const suggestionItemSchema = z.object({
  // canonical
  text: z.string(),
  type: z.enum(['advice','emotional_support','communication_guidance','boundary_setting','conflict_resolution']),
  confidence: z.number().min(0).max(1),
  reason: z.string(),
  attachmentFriendly: z.boolean().optional(),
  category: z.enum(['communication','emotional','relationship','conflict_resolution']).optional(),

  // backend extras (passthrough, but typed)
  id: z.union([z.number(), z.string()]).optional(),
  priority: z.number().optional(),
  context_specific: z.boolean().optional(),
  attachment_informed: z.boolean().optional(),
  categories: z.array(z.string()).optional(),
}).passthrough();

export type SuggestionItem = z.infer<typeof suggestionItemSchema>;

// Analysis results schema
export const originalAnalysisSchema = z.object({
  tone: z.string().describe('Detected tone of the original message'),
  sentiment: z.number().min(-1).max(1).describe('Sentiment score (-1 to 1)'),
  clarity_score: z.number().min(0).max(1).describe('Clarity score (0 to 1)'),
  empathy_score: z.number().min(0).max(1).describe('Empathy score (0 to 1)'),
  attachment_indicators: z.array(z.string()).optional().describe('Detected attachment style indicators'),
  communication_patterns: z.array(z.string()).optional().describe('Identified communication patterns'),
});

export type OriginalAnalysis = z.infer<typeof originalAnalysisSchema>;

/** METADATA — allow backend keys via passthrough */
export const responseMetadataSchema = z.object({
  suggestion_count: z.number(),
  processing_time_ms: z.number(),
  model_version: z.string(),
  features_used: z.array(z.string()).optional(),
  attachment_style_applied: z.string().optional(),

  // backend present keys (allowed, not required)
  status: z.string().optional(),
  attachment_informed: z.boolean().optional(),
}).passthrough();

export type ResponseMetadata = z.infer<typeof responseMetadataSchema>;

// Accept both canonical & backend response; keep success/version/ui fields
export const suggestionResponseSchema = z.object({
  // canonical
  text: z.string().optional(),               // canonical original text
  suggestions: z.array(suggestionItemSchema),
  original_analysis: originalAnalysisSchema.optional(),
  metadata: responseMetadataSchema,
  ui_tone: z.enum(['clear','caution','alert']).optional(),
  ui_distribution: z.object({
    clear: z.number().min(0).max(1).optional(),
    caution: z.number().min(0).max(1).optional(),
    alert: z.number().min(0).max(1).optional(),
  }).optional(),
  client_seq: z.number().optional(),
  success: z.boolean().default(true),
  version: z.string().default('1.0.0'),

  // backend fields (presently returned by your endpoint)
  ok: z.boolean().optional(),
  userId: z.string().optional(),
  original_text: z.string().optional(),      // backend name for original input
  context: z.string().optional(),
  analysis_meta: z.any().optional(),         // keep loose; already summarized into metadata above
  isNewUser: z.boolean().optional(),
  attachmentEstimate: z.any().optional(),
}).passthrough().refine(
  (v) => typeof v.text === 'string' || typeof v.original_text === 'string',
  { message: 'Either "text" or "original_text" must be present on SuggestionResponse.' }
);

export type SuggestionResponse = z.infer<typeof suggestionResponseSchema>;

// Validation schemas for different contexts
export const conflictSuggestionRequestSchema = suggestionRequestSchema.extend({
  context: z.literal('conflict').describe('Conflict resolution context'),
});

export const repairSuggestionRequestSchema = suggestionRequestSchema.extend({
  context: z.literal('repair').describe('Relationship repair context'),
});

export const boundarySuggestionRequestSchema = suggestionRequestSchema.extend({
  context: z.literal('boundary').describe('Boundary setting context'),
});

export const professionalSuggestionRequestSchema = suggestionRequestSchema.extend({
  context: z.literal('professional').describe('Professional communication context'),
});

export const generalSuggestionRequestSchema = suggestionRequestSchema.extend({
  context: z.literal('general').describe('General communication context'),
});

// Export context-specific types
export type ConflictSuggestionRequest = z.infer<typeof conflictSuggestionRequestSchema>;
export type RepairSuggestionRequest = z.infer<typeof repairSuggestionRequestSchema>;
export type BoundarySuggestionRequest = z.infer<typeof boundarySuggestionRequestSchema>;
export type ProfessionalSuggestionRequest = z.infer<typeof professionalSuggestionRequestSchema>;
export type GeneralSuggestionRequest = z.infer<typeof generalSuggestionRequestSchema>;