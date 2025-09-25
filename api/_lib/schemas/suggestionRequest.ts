// api/_lib/schemas/suggestionRequest.ts
import { z } from 'zod';
import { toneResponseSchema } from './toneRequest';

/**
 * Enhanced SuggestionRequest schema matching the JSON schema structure
 * Schema for generating therapy advice and communication guidance
 * Version: 1.0.0 - Last Updated: 2025-09-17
 */

// Tone override enum (matching JSON schema)
export const toneOverrideSchema = z.enum(['alert', 'caution', 'clear']).describe('Optional override for detected tone');

// Attachment style enum (matching JSON schema)
export const attachmentStyleSchema = z.enum(['anxious', 'avoidant', 'disorganized', 'secure']).describe('User attachment style');

// Context enum for better type safety across the stack
export const contextSchema = z.enum(['general', 'conflict', 'repair', 'boundary', 'planning', 'professional', 'romantic']).optional().describe('Communication context classification');

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
  context: z.string().optional().describe('Detected conversation context from tone analysis (e.g., conflict, repair, planning)'),
  // iOS Coordinator meta fields
  source: z.string().optional().describe('Request source (e.g., keyboard_tone_button, keyboard_manual)'),
  request_type: z.string().optional().describe('Type of request (e.g., suggestion)'),
  emotional_state: z.string().optional().describe('User emotional state'),
  communication_style: z.string().optional().describe('User communication style'),
  emotional_bucket: z.string().optional().describe('User emotional bucket'),
  personality_type: z.string().optional().describe('User personality type'),
  new_user: z.boolean().optional().describe('Whether user is new'),
  attachment_provisional: z.boolean().optional().describe('Whether attachment style is provisional'),
  learning_days_remaining: z.number().optional().describe('Days remaining in learning period'),
  attachment_source: z.string().optional().describe('Source of attachment style determination'),
}).passthrough().describe('Optional metadata for tracing and UX decisions');

// Main SuggestionRequest schema (matching JSON schema structure + canonical v1 contract)
export const suggestionRequestSchema = z.object({
  text: z.string()
    .min(1, 'A valid message text (1–5000 characters) is required')
    .max(5000, 'A valid message text (1–5000 characters) is required')
    .describe('The message to analyze and provide therapy advice for'),
  
  // ✅ CANONICAL V1 CONTRACT FIELDS - Required for coordinator integration
  text_sha256: z.string().optional().describe('SHA256 hash of the text for integrity validation'),
  client_seq: z.number().optional().describe('Client sequence number for last-writer-wins and request ordering'),
  compose_id: z.string().optional().describe('Unique compose session identifier for request deduplication'),
  
  // Enhanced toneAnalysis to match SuggestionInputV1 interface
  toneAnalysis: z.object({
    classification: z.string().describe('Tone classification from tone.ts (e.g., clear, caution, alert, neutral)'),
    confidence: z.number().min(0).max(1).describe('Confidence score for the tone classification'),
    ui_distribution: z.object({
      clear: z.number().min(0).max(1).describe('Clear tone probability'),
      caution: z.number().min(0).max(1).describe('Caution tone probability'),
      alert: z.number().min(0).max(1).describe('Alert tone probability'),
    }).describe('UI distribution buckets that sum to ~1.0'),
    intensity: z.number().min(0).max(1).optional().describe('Emotional intensity score'),
  }).optional().describe('Pre-computed tone analysis result from coordinator - when provided, eliminates duplicate tone analysis computation'),
  
  context: z.string().optional().describe('Communication context - auto-detected from text if not provided'),
  attachmentStyle: z.string().optional().describe('User attachment style (secure, anxious, avoidant, disorganized)'),
  
  // Rich analysis data from tone.ts 
  rich: z.object({
    emotions: z.record(z.number()).optional().describe('Emotion scores from tone analysis'),
    sentiment_score: z.number().optional().describe('Sentiment score from tone analysis'),
    linguistic_features: z.record(z.any()).optional().describe('Linguistic features from tone analysis'),
    context_analysis: z.record(z.any()).optional().describe('Context analysis from tone analysis'),
    attachment_insights: z.array(z.any()).optional().describe('Attachment insights from tone analysis'),
    categories: z.array(z.string()).optional().describe('Categories from tone pattern matching'),
    timestamp: z.string().optional().describe('Analysis timestamp'),
    raw_tone: z.string().optional().describe('Raw tone classification'),
    metadata: z.record(z.any()).optional().describe('Additional metadata from tone analysis'),
    attachmentEstimate: z.record(z.any()).optional().describe('Attachment estimate from analysis'),
    isNewUser: z.boolean().optional().describe('Whether user is new'),
  }).optional().describe('Rich analysis data from tone endpoint'),
  
  // Legacy fields for backward compatibility
  toneOverride: toneOverrideSchema.optional().describe('Optional override for detected tone. Useful for testing or manual control'),
  features: featuresSchema.optional().describe('Feature flags to include in the response. Common values: advice, quick_fixes, evidence, emotional_support'),
  meta: metaSchema.optional().describe('Optional metadata for tracing and UX decisions'),
  
  // Client sequencing fields (alternative names for compatibility)
  clientSeq: z.number().optional().describe('Alternative client sequence number field'),
  requestId: z.string().optional().describe('Unique request identifier for tracing'),
  
  // iOS Coordinator fields
  userId: z.string().optional().describe('User identifier from iOS coordinator'),
  userEmail: z.union([z.string().email(), z.null()]).optional().describe('User email from iOS coordinator'),
  maxSuggestions: z.number().min(1).max(10).optional().describe('Maximum number of suggestions to return'),
  conversationHistory: z.array(z.any()).optional().describe('Conversation history from iOS coordinator'),
  user_profile: z.record(z.any()).optional().describe('User profile data from iOS coordinator'),
}).passthrough().describe('Request schema for generating therapy advice and communication guidance');

export type SuggestionRequest = z.infer<typeof suggestionRequestSchema>;

/** SUGGESTION ITEM — accept backend fields too */
export const suggestionItemSchema = z.object({
  // canonical
  text: z.string().optional(), // text is optional for micro_advice type
  advice: z.string().optional(), // for micro_advice type
  type: z.enum(['advice','emotional_support','communication_guidance','boundary_setting','conflict_resolution','rewrite','micro_advice']),
  confidence: z.number().min(0).max(1),
  reason: z.string().optional(), // optional for micro_advice
  attachmentFriendly: z.boolean().optional(),
  category: z.enum(['communication','emotional','relationship','conflict_resolution']).optional(),

  // backend extras (passthrough, but typed)
  id: z.union([z.number(), z.string()]).optional(),
  priority: z.number().optional(),
  context_specific: z.boolean().optional(),
  attachment_informed: z.boolean().optional(),
  categories: z.array(z.string()).optional(),
  
  // micro_advice specific fields
  meta: z.object({
    contexts: z.array(z.string()).optional(),
    contextLink: z.array(z.string()).optional(),
    triggerTone: z.string().optional(),
    attachmentStyles: z.array(z.string()).optional(),
    intent: z.array(z.string()).optional(),
    tags: z.array(z.string()).optional(),
    patterns: z.array(z.string()).optional(),
    source: z.string().optional()
  }).optional(),
  score: z.number().optional()
}).passthrough();

export type SuggestionItem = z.infer<typeof suggestionItemSchema>;

// Analysis results schema - Enhanced to include complete therapy-relevant data
export const originalAnalysisSchema = z.object({
  tone: z.string().describe('Detected tone of the original message'),
  confidence: z.number().min(0).max(1).describe('Tone detection confidence'),
  sentiment: z.number().min(-1).max(1).describe('Sentiment score (-1 to 1)'),
  sentiment_score: z.number().min(-1).max(1).optional().describe('Alternative sentiment score field'),
  intensity: z.number().min(0).max(1).optional().describe('Emotional intensity score'),
  clarity_score: z.number().min(0).max(1).describe('Clarity score (0 to 1)'),
  empathy_score: z.number().min(0).max(1).describe('Empathy score (0 to 1)'),
  
  // ✅ ADD MISSING REQUIRED FIELDS for canonical v1 contract compatibility
  emotions: z.record(z.any()).optional().describe('Emotion analysis from tone endpoint'),
  evidence: z.array(z.string()).optional().describe('Evidence for tone classification'),
  communication_patterns: z.array(z.string()).optional().describe('Identified communication patterns'),
  metadata: z.record(z.any()).optional().describe('Analysis metadata'),
  complete_analysis_available: z.boolean().optional().describe('Whether complete analysis data is available'),
  tone_analysis_source: z.enum(['coordinator_cache', 'fresh_analysis', 'override']).optional().describe('Source of tone analysis'),
  
  // Enhanced linguistic and contextual analysis
  linguistic_features: z.object({
    formality_level: z.number().min(0).max(1).optional(),
    emotional_complexity: z.number().min(0).max(1).optional(),
    assertiveness: z.number().min(0).max(1).optional(),
    empathy_indicators: z.array(z.string()).optional(),
    potential_misunderstandings: z.array(z.string()).optional(),
  }).optional().describe('Linguistic feature analysis'),
  
  context_analysis: z.object({
    appropriateness_score: z.number().min(0).max(1).optional(),
    relationship_impact: z.enum(['positive', 'neutral', 'negative']).optional(),
    suggested_adjustments: z.array(z.string()).optional(),
    relationship_dynamic: z.string().optional(),
    communication_pattern: z.string().optional(),
    escalation_risk: z.enum(['low', 'medium', 'high']).optional(),
  }).optional().describe('Contextual relationship analysis'),
  
  attachment_indicators: z.array(z.string()).optional().describe('Detected attachment style indicators'),
  attachmentInsights: z.array(z.string()).optional().describe('Attachment-specific insights'),
  
  // ✅ PRESERVE ORIGINAL vs ADJUSTED DISTRIBUTIONS for observability
  ui_tone_original: z.string().optional().describe('Original tone from server before adjustments'),
  ui_distribution_original: z.object({
    clear: z.number().min(0).max(1).optional(),
    caution: z.number().min(0).max(1).optional(),
    alert: z.number().min(0).max(1).optional(),
  }).optional().describe('Original distribution from server before adjustments'),
  
  // UI consistency fields (adjusted for suggestions context)
  ui_tone: z.enum(['clear','caution','alert','neutral']).optional().describe('UI bucket for the pill color (adjusted)'),
  ui_distribution: z.object({
    clear: z.number().min(0).max(1).optional(),
    caution: z.number().min(0).max(1).optional(),
    alert: z.number().min(0).max(1).optional(),
  }).optional().describe('Bucket probabilities used to derive ui_tone (adjusted)'),
});

export type OriginalAnalysis = z.infer<typeof originalAnalysisSchema>;

/** METADATA — Enhanced to track complete analysis processing */
export const responseMetadataSchema = z.object({
  suggestion_count: z.number(),
  processingTimeMs: z.number(),
  model_version: z.string(),
  features_used: z.array(z.string()).optional(),
  attachment_style_applied: z.string().optional(),
  
  // Enhanced analysis tracking
  tone_analysis_source: z.enum(['coordinator_cache', 'fresh_analysis', 'override', 'missing']).optional().describe('Source of tone analysis data'),
  complete_analysis_available: z.boolean().optional().describe('Whether complete linguistic and contextual analysis was available'),
  linguistic_features_used: z.boolean().optional().describe('Whether linguistic features were available and used'),
  context_analysis_used: z.boolean().optional().describe('Whether context analysis was available and used'),
  attachment_insights_count: z.number().optional().describe('Number of attachment insights processed'),

  // backend present keys (allowed, not required)
  status: z.string().optional(),
  attachment_informed: z.boolean().optional(),
  
  // Legacy field for backward compatibility
  processing_time_ms: z.number().optional(),
}).passthrough();

export type ResponseMetadata = z.infer<typeof responseMetadataSchema>;

// Accept both canonical & backend response; keep success/version/ui fields
export const suggestionResponseSchema = z.object({
  // canonical
  text: z.string().optional(),               // canonical original text
  suggestions: z.array(suggestionItemSchema),
  original_analysis: originalAnalysisSchema.optional(),
  metadata: responseMetadataSchema,
  ui_tone: z.enum(['clear','caution','alert','neutral']).optional(),
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