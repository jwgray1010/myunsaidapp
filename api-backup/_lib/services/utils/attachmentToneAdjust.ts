// api/_lib/services/utils/attachmentToneAdjust.ts
import { logger } from '../../logger';

type Bucket = 'clear' | 'caution' | 'alert';
type Distribution = Record<Bucket, number>;

// NaN-proof numeric helper
const n = (x: unknown, d = 0): number => {
  const v = Number(x);
  return Number.isFinite(v) ? v : d;
};

// Normalize distribution helper
function normalizeDist(d: Distribution, fallback: Distribution = {clear: 0.34, caution: 0.33, alert: 0.33}): Distribution {
  const sum = n(d.clear) + n(d.caution) + n(d.alert);
  if (!(sum > 0)) return fallback;
  return { 
    clear: n(d.clear) / sum, 
    caution: n(d.caution) / sum, 
    alert: n(d.alert) / sum 
  };
}

export function adjustToneByAttachment(
  rawTone: { classification: string; confidence: number },
  baseDist: Distribution,
  style: 'anxious' | 'avoidant' | 'disorganized' | 'secure',
  ctx: 'CTX_CONFLICT' | 'CTX_PLANNING' | 'CTX_BOUNDARY' | 'CTX_REPAIR' | string,
  intensity: number,
  cfg: any
): Distribution {
  // Normalize baseDist on input
  const normalizedBaseDist = normalizeDist(baseDist);
  
  const ov = cfg?.overrides?.[style];
  if (!ov) {
    logger.debug(`No attachment tone overrides found for style: ${style}`);
    return normalizedBaseDist;
  }

  // Clone the base distribution as pseudo-logits
  let logits: Record<Bucket, number> = { 
    clear: normalizedBaseDist.clear,
    caution: normalizedBaseDist.caution,
    alert: normalizedBaseDist.alert
  };

  const capOff = n(cfg?.defaults?.cap_limits?.per_tone_offset_max, 0.35);
  const capMul = n(cfg?.defaults?.cap_limits?.per_tone_multiplier_max, 1.40);

  // 1) Apply tone_offsets (additive)
  const offsets = ov.tone_offsets ?? cfg?.defaults?.tone_offsets ?? {};
  for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
    const offset = n(offsets[bucket], 0);
    const clampedOffset = Math.max(-capOff, Math.min(capOff, offset));
    logits[bucket] += clampedOffset;
  }

  // 2) Apply tone_multipliers (multiplicative)
  const multipliers = ov.tone_multipliers ?? cfg?.defaults?.tone_multipliers ?? {};
  for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
    const multiplier = n(multipliers[bucket], 1.0);
    const clampedMultiplier = Math.min(capMul, Math.max(1 / capMul, multiplier));
    logits[bucket] *= clampedMultiplier;
  }

  // 3) Apply context_boosts (additive by context)
  const contextBoosts = ov.context_boosts?.[ctx] ?? cfg?.defaults?.context_boosts?.[ctx] ?? null;
  if (contextBoosts) {
    for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
      const boost = n(contextBoosts[bucket], 0);
      logits[bucket] += boost;
    }
  }

  // 4) Apply intensity_blend (weighted shift from clear to caution/alert)
  const blendWeight = n(ov.intensity_blend?.weight ?? cfg?.defaults?.intensity_blend?.weight, 0.2);
  const clampedIntensity = Math.max(0, Math.min(1, n(intensity, 0)));
  
  // Cap intensity shift to available mass - ensure shift <= logits.clear
  const maxShift = Math.max(0, logits.clear);
  const intendedShift = blendWeight * clampedIntensity * logits.clear;
  const shift = Math.min(intendedShift, maxShift);
  
  logits.clear -= shift;
  logits.caution += shift * 0.6; // 60% to caution
  logits.alert += shift * 0.4;   // 40% to alert

  // Ensure no negative values after all adjustments
  logits.clear = Math.max(0, logits.clear);
  logits.caution = Math.max(0, logits.caution);
  logits.alert = Math.max(0, logits.alert);

  // Normalize back to distribution (sum = 1) using safe helper
  const adjustedDist = normalizeDist(logits);

  logger.debug(`Attachment tone adjustment for ${style}:`, {
    context: ctx,
    intensity: clampedIntensity,
    baseDist: normalizedBaseDist,
    adjustedDist,
    rawTone: rawTone.classification
  });

  return adjustedDist;
}

export function applyThresholdShift(
  distribution: Distribution,
  style: 'anxious' | 'avoidant' | 'disorganized' | 'secure',
  cfg: any
): { primary: Bucket; distribution: Distribution } {
  const ov = cfg?.overrides?.[style];
  if (!ov) {
    // No threshold shift, return original primary with deterministic tie-breaking
    const entries = Object.entries(distribution) as [Bucket, number][];
    const sortedEntries = entries.sort((a, b) => {
      const diff = b[1] - a[1];
      if (Math.abs(diff) < 1e-9) {
        // Stable tie-break: clear > caution > alert
        const order = { clear: 3, caution: 2, alert: 1 };
        return order[b[0]] - order[a[0]];
      }
      return diff;
    });
    const primary = sortedEntries[0][0];
    return { primary, distribution };
  }

  const thresholdShift = ov.threshold_shift ?? cfg?.defaults?.threshold_shift ?? {};
  
  // Apply threshold shifts using safe numeric reads
  const shift = {
    clear: n(thresholdShift.clear, 0),
    caution: n(thresholdShift.caution, 0),
    alert: n(thresholdShift.alert, 0),
  };
  
  const biased = {
    clear: n(distribution.clear, 0) - shift.clear,
    caution: n(distribution.caution, 0) - shift.caution,
    alert: n(distribution.alert, 0) - shift.alert,
  };

  // Find primary from biased distribution with stable tie-breaking
  const entries = Object.entries(biased) as [Bucket, number][];
  const sortedEntries = entries.sort((a, b) => {
    const diff = b[1] - a[1];
    if (Math.abs(diff) < 1e-9) {
      // Stable tie-break: clear > caution > alert
      const order = { clear: 3, caution: 2, alert: 1 };
      return order[b[0]] - order[a[0]];
    }
    return diff;
  });
  const primary = sortedEntries[0][0];
  
  // Check if the top two are very close (within 0.03)
  const topTwo = sortedEntries.slice(0, 2);
  const isCloseCall = topTwo.length === 2 && Math.abs(topTwo[0][1] - topTwo[1][1]) <= 0.03;
  
  if (isCloseCall) {
    logger.debug(`Threshold shift applied for ${style}: ${topTwo[1][0]} → ${primary}`, {
      original: distribution,
      biased,
      shift: thresholdShift
    });
  }

  return { primary, distribution }; // Return original distribution, only primary is affected
}