/**
 * Context key canonicalization to prevent "conflict" vs "CTX_CONFLICT" mismatches
 */

export const CONTEXT_ALIASES: Record<string, string> = {
  // Legacy system codes -> human-friendly
  CTX_CONFLICT: "conflict",
  CTX_REPAIR: "repair", 
  CTX_BOUNDARY: "boundary",
  CTX_PLANNING: "planning",
  CTX_PROFESSIONAL: "professional",
  CTX_ROMANTIC: "romantic",
  CTX_GENERAL: "general",
  
  // Normalize common variations
  "general": "general",
  "conflict": "conflict",
  "repair": "repair",
  "boundary": "boundary", 
  "planning": "planning",
  "professional": "professional",
  "romantic": "romantic",
  
  // Handle emotional contexts that might be detected
  "emotional": "conflict", // Emotional content usually maps to conflict handling
  "anger": "conflict",
  "frustrated": "conflict",
  "upset": "conflict",
  "sad": "repair",
  "hurt": "repair"
};

/**
 * Canonical context keys used throughout the system
 */
export const CANONICAL_CONTEXTS = [
  "general",
  "conflict", 
  "repair",
  "boundary",
  "planning", 
  "professional",
  "romantic"
] as const;

export type CanonicalContext = typeof CANONICAL_CONTEXTS[number];

/**
 * Normalize any context key to canonical form
 */
export function normalizeContextKey(key?: string): string {
  if (!key) return "general";
  const k = key.trim().toLowerCase();
  return CONTEXT_ALIASES[k] ?? k;
}

/**
 * Context scoring thresholds for admission
 */
export const CTX_CONFIG = {
  MIN_SCORE: Number(process.env.SUGG_CTX_SCORE_MIN ?? "0.35"),
  TOP_K: Number(process.env.SUGG_CTX_TOPK ?? "2"),
  STRICT_MODE: process.env.SUGGESTIONS_STRICT_CONTEXT === "true"
};