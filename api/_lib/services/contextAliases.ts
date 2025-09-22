/**
 * Context key canonicalization & alias expansion.
 * Backward-compatible with normalizeContextKey(), and adds normalizeContexts() for multi-mapping.
 */

export const CANONICAL_CONTEXTS = [
  "general",
  "conflict",
  "repair",
  "boundary",
  "planning",
  "professional",
  "romantic",
  "gratitude"
] as const;

export type CanonicalContext = typeof CANONICAL_CONTEXTS[number];

/**
 * One-to-one canonicalization for legacy/system codes.
 * (Used by normalizeContextKey for backward compatibility.)
 */
export const CONTEXT_ALIASES_1to1: Record<string, CanonicalContext> = {
  // Legacy system codes -> human-friendly
  CTX_CONFLICT: "conflict",
  CTX_REPAIR: "repair",
  CTX_BOUNDARY: "boundary",
  CTX_PLANNING: "planning",
  CTX_PROFESSIONAL: "professional",
  CTX_ROMANTIC: "romantic",
  CTX_GENERAL: "general",
  CTX_GRATITUDE: "gratitude",

  // Already-canonical (idempotent)
  general: "general",
  conflict: "conflict",
  repair: "repair",
  boundary: "boundary",
  planning: "planning",
  professional: "professional",
  romantic: "romantic",
  gratitude: "gratitude",

  // Heuristic emotions -> best-fit canonicals
  emotional: "conflict",
  anger: "conflict",
  frustrated: "conflict",
  upset: "conflict",
  sad: "repair",
  hurt: "repair"
};

/**
 * Many-to-one(+general) expansion.
 * Use this for retrieval & guardrails so similar intents survive filtering.
 */
export const CONTEXT_ALIASES_EXPAND: Record<string, CanonicalContext[]> = {
  // gratitude / appreciation family
  appreciation: ["gratitude", "general"],
  grateful: ["gratitude", "general"],
  thanks: ["gratitude", "general"],
  thank_you: ["gratitude", "general"],
  acknowledgment: ["gratitude", "general"],

  // keep common variants you already see in detectors
  positive_reflection: ["gratitude", "general"],

  // map legacy codes to arrays too (safe if someone calls normalizeContexts on them)
  CTX_GRATITUDE: ["gratitude", "general"],

  // emotional shortcuts (mirror your 1to1 but as arrays)
  emotional: ["conflict", "general"],
  anger: ["conflict", "general"],
  frustrated: ["conflict", "general"],
  upset: ["conflict", "general"],
  sad: ["repair", "general"],
  hurt: ["repair", "general"]
};

/**
 * Context scoring thresholds for admission
 */
export const CTX_CONFIG = {
  MIN_SCORE: Number(process.env.SUGG_CTX_SCORE_MIN ?? "0.35"),
  TOP_K: Number(process.env.SUGG_CTX_TOPK ?? "2"),
  STRICT_MODE: process.env.SUGGESTIONS_STRICT_CONTEXT === "true"
};

/**
 * Backward-compatible single-key canonicalization.
 * Prefer normalizeContexts() in the suggestions pipeline.
 */
export function normalizeContextKey(key?: string): CanonicalContext {
  if (!key) return "general";
  const k = key.trim().toLowerCase();
  return CONTEXT_ALIASES_1to1[k] ?? (k as CanonicalContext);
}

/**
 * Multi-context expansion with safe fallback.
 * - Always includes 'general'
 * - Dedupes
 * - Respects STRICT_MODE by trimming to TOP_K highest-scoring contexts (if provided)
 */
export function normalizeContexts(
  raw?: string | string[],
  scored?: Partial<Record<CanonicalContext, number>>
): CanonicalContext[] {
  const inputs = (Array.isArray(raw) ? raw : [raw]).filter(Boolean) as string[];

  // Seed with general
  const out = new Set<CanonicalContext>(["general"]);

  for (const key of inputs) {
    const k = key.trim().toLowerCase();

    // Expand if we have an array mapping
    const expanded = CONTEXT_ALIASES_EXPAND[k];
    if (expanded && expanded.length) {
      expanded.forEach(c => out.add(c));
      continue;
    }

    // Else fall back to 1:1 canonical
    const canon = CONTEXT_ALIASES_1to1[k] ?? (k as CanonicalContext);
    if (CANONICAL_CONTEXTS.includes(canon)) out.add(canon);
  }

  // If STRICT_MODE and scores given, prune to top-K by score (but never drop 'general')
  if (CTX_CONFIG.STRICT_MODE && scored) {
    const keepGeneral = out.has("general");
    const rest = Array.from(out).filter(c => c !== "general");
    rest.sort((a, b) => (scored[b] ?? 0) - (scored[a] ?? 0));

    const pruned = rest.slice(0, Math.max(1, CTX_CONFIG.TOP_K)); // keep at least 1 besides 'general'
    const final = new Set<CanonicalContext>(keepGeneral ? ["general"] : []);
    pruned.forEach(c => final.add(c));

    // Safety: if pruning removed everything, fall back to ['general']
    return (final.size ? Array.from(final) : ["general"]) as CanonicalContext[];
  }

  return Array.from(out) as CanonicalContext[];
}