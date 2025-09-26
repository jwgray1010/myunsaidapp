// api/_lib/utils/priors.ts
// Local prior blending utilities for attachment style estimation

export interface AttachmentScores {
  secure: number;
  anxious: number;
  avoidant: number;
  disorganized: number;
}

export interface NormalizedScores extends AttachmentScores {}

const clamp01 = (x: number) => (Number.isFinite(x) ? Math.min(1, Math.max(0, x)) : 0);

/**
 * Normalize (anxious, avoidant, disorganized, secure) onto a simplex (sum = 1).
 * - Negative inputs are clamped to 0
 * - Missing/NaN treated as 0
 * - If all zero, returns uniform distribution
 */
export function normalizeScores(s?: Partial<AttachmentScores> | null): NormalizedScores {
  const safe = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, v) : 0);

  const anxious = safe(s?.anxious);
  const avoidant = safe(s?.avoidant);
  const disorganized = safe(s?.disorganized);
  const secure = safe(s?.secure);

  let sum = anxious + avoidant + disorganized + secure;

  // If everything is zero, return uniform (avoids accidental NaNs)
  if (sum <= 0) {
    return { anxious: 0.25, avoidant: 0.25, disorganized: 0.25, secure: 0.25 };
  }

  // Tiny epsilon protects against pathological float sums
  sum = sum || 1e-9;

  return {
    anxious: anxious / sum,
    avoidant: avoidant / sum,
    disorganized: disorganized / sum,
    secure: secure / sum,
  };
}

/**
 * Prior weight that decays from 1 → floor as observations accumulate.
 * - `daysObserved` is clamped to [0, +inf)
 * - `learningDays` is clamped to [1, +inf) so you never divide by 0
 * - Returns in [floor, 1]
 */
export function defaultPriorWeight(
  daysObserved: number,
  learningDays: number,
  floor = 0.2
): number {
  const d = Math.max(0, Number.isFinite(daysObserved) ? daysObserved : 0);
  const L = Math.max(1, Number.isFinite(learningDays) ? learningDays : 1);
  const base = 1 - Math.min(1, d / L);
  return Math.max(0, Math.min(1, Math.max(floor, base)));
}

/**
 * Blend a prior distribution with a new observation and renormalize.
 * `w` is the prior weight in [0,1]; higher = trust prior more.
 */
export function blendScores(
  prior: Partial<AttachmentScores> | null | undefined,
  observation: Partial<AttachmentScores> | null | undefined,
  w: number
): NormalizedScores {
  const p = normalizeScores(prior);
  const o = normalizeScores(observation);
  const wp = clamp01(w);
  const wo = 1 - wp;

  return normalizeScores({
    anxious: wp * p.anxious + wo * o.anxious,
    avoidant: wp * p.avoidant + wo * o.avoidant,
    disorganized: wp * p.disorganized + wo * o.disorganized,
    secure: wp * p.secure + wo * o.secure,
  });
}

/**
 * Type guard (handy in callers)
 */
export function isNormalized(x: AttachmentScores): x is NormalizedScores {
  const sum = x.anxious + x.avoidant + x.disorganized + x.secure;
  return (
    Object.values(x).every((v) => Number.isFinite(v as number) && (v as number) >= 0) &&
    Math.abs(sum - 1) < 1e-6
  );
}
