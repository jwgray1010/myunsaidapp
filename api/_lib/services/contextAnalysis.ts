// api/_lib/schemas/normalize.ts (unchanged below; only context filters updated)

// api/_lib/services/contextAppropriateness.ts
/**
 * Context appropriateness checking with score-based admission
 */

import { normalizeContextKey, CTX_CONFIG } from './contextAliases';

export type ContextScores = Record<string, number>;

// Local safe defaults (used if CTX_CONFIG is partial)
const DEF = {
  STRICT_MODE: false,
  TOP_K: 3,
  MIN_SCORE: 0.18,
  CONFLICT_ALIASES: ['conflict','escalation','rupture','blame','defense','boundary','withdrawal','jealousy','safety','presence','anxious.pattern','disorganized.pattern']
} as const;

function cfg<K extends keyof typeof DEF>(k: K) {
  return (CTX_CONFIG?.[k] ?? DEF[k]) as unknown as (typeof DEF)[K];
}

function sanitizeScores(ctxScores: ContextScores = {}): ContextScores {
  const out: ContextScores = {};
  for (const [k, v] of Object.entries(ctxScores)) {
    const n = Number(v);
    if (isFinite(n) && n > 0) out[normalizeContextKey(k)] = n;
  }
  return out;
}

function topContexts(ctxScores: ContextScores, k = cfg('TOP_K')): Array<[string, number]> {
  return Object.entries(ctxScores)
    .sort((a, b) => b[1] - a[1])
    .slice(0, Math.max(1, k));
}

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
  const links = new Set((suggestion.contextLink || []).map(normalizeContextKey));
  const scores = sanitizeScores(ctxScores);
  const MIN = cfg('MIN_SCORE');

  // Rule 0: If suggestion declares no contexts at all, treat as "general-ish"
  if (!suggContexts.size) return true;

  // Rule 1: Always allow suggestions marked as "general"
  if (suggContexts.has('general')) return true;

  // Rule 2: Direct context match
  if (suggContexts.has(reqCtx)) return true;

  // Rule 2.1: Link match against the current request context (cheap early allow)
  if (links.has(reqCtx)) return true;

  // Rule 3: Strict mode stops here
  if (cfg('STRICT_MODE')) return false;

  // Rule 4: Score-based admission for top contexts
  const tops = topContexts(scores, cfg('TOP_K'));
  for (const [ctx, score] of tops) {
    if (score >= MIN && suggContexts.has(ctx as any)) return true;
    // Also allow if links point to an active top context
    if (score >= MIN && links.has(ctx as any)) return true;
  }

  // Rule 5: Special handling for conflict-related families
  // If top context is "conflict-ish", then allow any suggestion that is conflict-ish
  const conflictSet = new Set(cfg('CONFLICT_ALIASES').map(normalizeContextKey));
  const top = tops[0]; // tops is never empty (topContexts returns at least one or [])
  if (top && top[1] >= MIN) {
    const topCtx = normalizeContextKey(top[0]);
    const suggestionIsConflictish = Array.from(suggContexts).some(c => conflictSet.has(c));
    const linksAreConflictish = Array.from(links).some(c => conflictSet.has(c));
    const topIsConflictish = conflictSet.has(topCtx) || topCtx === 'emotional';

    if (topIsConflictish && (suggestionIsConflictish || linksAreConflictish)) {
      return true;
    }
  }

  return false;
}

/**
 * Log context filtering decisions for debugging
 */
export function logContextFilter(
  suggestion: { contexts?: string[]; contextLink?: string[]; id?: string },
  requestCtx: string,
  ctxScores: ContextScores,
  allowed: boolean,
  logger: any
): void {
  const scores = sanitizeScores(ctxScores);
  const top3 = topContexts(scores, 3).map(([k, v]) => [normalizeContextKey(k), v] as const);

  logger.debug('Context appropriateness check', {
    suggestionId: suggestion.id,
    allowed,
    requestCtx: normalizeContextKey(requestCtx),
    suggestionContexts: (suggestion.contexts || []).map(normalizeContextKey),
    contextLinks: (suggestion.contextLink || []).map(normalizeContextKey),
    topContexts: top3,
    threshold: cfg('MIN_SCORE'),
    topK: cfg('TOP_K'),
    strictMode: cfg('STRICT_MODE')
  });
}

/**
 * Calculate context link bonus for scoring
 * - Scales with number of overlaps
 * - Caps impact to keep it a nudge, not a flip
 */
export function getContextLinkBonus(
  suggestion: { contextLink?: string[] },
  topContexts: string[]
): number {
  const links = (suggestion.contextLink || []).map(normalizeContextKey);
  if (links.length === 0 || topContexts.length === 0) return 0;

  const linkSet = new Set(links);
  const topSet = new Set(topContexts.map(normalizeContextKey));
  let overlap = 0;
  for (const l of Array.from(linkSet)) if (topSet.has(l)) overlap++;

  if (overlap === 0) return 0;

  // Base 0.05 per your original; scale gently with overlap and cap
  const bonus = 0.05 * Math.min(1, overlap / Math.max(1, topSet.size));
  return Math.min(0.10, bonus); // never more than +0.10 total
}
