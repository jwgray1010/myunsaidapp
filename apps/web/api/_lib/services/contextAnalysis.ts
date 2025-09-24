/**
 * Context appropriateness checking with score-based admission
 */

import { normalizeContextKey, CTX_CONFIG } from './contextAliases';

export type ContextScores = Record<string, number>;

/**
 * Determine if a suggestion is appropriate for the given context
 * Uses softened rules to prevent over-filtering
 */
export function isContextAppropriate(
  suggestion: { 
    contexts?: string[];
    contextLink?: string[];
    id?: string;
  },
  requestCtx: string,
  ctxScores: ContextScores = {}
): boolean {
  const reqCtx = normalizeContextKey(requestCtx);
  const suggContexts = new Set((suggestion.contexts || []).map(normalizeContextKey));
  
  // Rule 1: Always allow suggestions marked as "general"
  if (suggContexts.has("general")) {
    return true;
  }
  
  // Rule 2: Direct context match
  if (suggContexts.has(reqCtx)) {
    return true;
  }
  
  // Rule 3: If strict mode is enabled, stop here
  if (CTX_CONFIG.STRICT_MODE) {
    return false;
  }
  
  // Rule 4: Score-based admission for top contexts
  const sortedContexts = Object.entries(ctxScores)
    .map(([k, v]) => [normalizeContextKey(k), v] as const)
    .sort((a, b) => b[1] - a[1])
    .slice(0, CTX_CONFIG.TOP_K);
  
  for (const [ctx, score] of sortedContexts) {
    if (score >= CTX_CONFIG.MIN_SCORE && suggContexts.has(ctx)) {
      return true;
    }
  }
  
  // Rule 5: Special handling for conflict-related suggestions
  // If the top context is conflict-related and this is a conflict suggestion
  const topContext = sortedContexts[0];
  if (topContext && topContext[1] >= CTX_CONFIG.MIN_SCORE) {
    const topCtx = topContext[0];
    if ((topCtx === "conflict" || topCtx === "emotional") && suggContexts.has("conflict")) {
      return true;
    }
  }
  
  return false;
}

/**
 * Log context filtering decisions for debugging
 */
export function logContextFilter(
  suggestion: { contexts?: string[]; id?: string },
  requestCtx: string,
  ctxScores: ContextScores,
  allowed: boolean,
  logger: any
): void {
  const topContexts = Object.entries(ctxScores)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([k, v]) => [normalizeContextKey(k), v]);
    
  logger.debug('Context appropriateness check', {
    suggestionId: suggestion.id,
    allowed,
    requestCtx: normalizeContextKey(requestCtx),
    suggestionContexts: (suggestion.contexts || []).map(normalizeContextKey),
    topContexts,
    threshold: CTX_CONFIG.MIN_SCORE,
    topK: CTX_CONFIG.TOP_K,
    strictMode: CTX_CONFIG.STRICT_MODE
  });
}

/**
 * Calculate context link bonus for scoring
 */
export function getContextLinkBonus(
  suggestion: { contextLink?: string[] },
  topContexts: string[]
): number {
  if (!suggestion.contextLink || suggestion.contextLink.length === 0) {
    return 0;
  }
  
  const normalizedLinks = suggestion.contextLink.map(normalizeContextKey);
  const normalizedTopContexts = topContexts.map(normalizeContextKey);
  
  const hasMatch = normalizedLinks.some(link => normalizedTopContexts.includes(link));
  return hasMatch ? 0.05 : 0;
}