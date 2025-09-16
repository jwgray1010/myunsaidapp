// api/_lib/services/utils/attachmentToneAdjust.ts
import { logger } from '../../logger';

type Bucket = 'clear' | 'caution' | 'alert';
type Distribution = Record<Bucket, number>;

export function adjustToneByAttachment(
  rawTone: { classification: string; confidence: number },
  baseDist: Distribution,
  style: 'anxious' | 'avoidant' | 'disorganized' | 'secure',
  ctx: 'CTX_CONFLICT' | 'CTX_PLANNING' | 'CTX_BOUNDARY' | 'CTX_REPAIR' | string,
  intensity: number,
  cfg: any
): Distribution {
  const ov = cfg?.overrides?.[style];
  if (!ov) {
    logger.debug(`No attachment tone overrides found for style: ${style}`);
    return baseDist;
  }

  // Clone the base distribution as pseudo-logits
  let logits: Record<Bucket, number> = { 
    clear: baseDist.clear,
    caution: baseDist.caution,
    alert: baseDist.alert
  };

  const capOff = cfg?.defaults?.cap_limits?.per_tone_offset_max ?? 0.35;
  const capMul = cfg?.defaults?.cap_limits?.per_tone_multiplier_max ?? 1.40;

  // 1) Apply tone_offsets (additive)
  const offsets = ov.tone_offsets ?? cfg?.defaults?.tone_offsets ?? {};
  for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
    const offset = Number(offsets[bucket] ?? 0);
    const clampedOffset = Math.max(-capOff, Math.min(capOff, offset));
    logits[bucket] += clampedOffset;
  }

  // 2) Apply tone_multipliers (multiplicative)
  const multipliers = ov.tone_multipliers ?? cfg?.defaults?.tone_multipliers ?? {};
  for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
    const multiplier = Number(multipliers[bucket] ?? 1.0);
    const clampedMultiplier = Math.min(capMul, Math.max(1 / capMul, multiplier));
    logits[bucket] *= clampedMultiplier;
  }

  // 3) Apply context_boosts (additive by context)
  const contextBoosts = ov.context_boosts?.[ctx] ?? cfg?.defaults?.context_boosts?.[ctx] ?? null;
  if (contextBoosts) {
    for (const bucket of ['clear', 'caution', 'alert'] as Bucket[]) {
      const boost = Number(contextBoosts[bucket] ?? 0);
      logits[bucket] += boost;
    }
  }

  // 4) Apply intensity_blend (weighted shift from clear to caution/alert)
  const blendWeight = ov.intensity_blend?.weight ?? cfg?.defaults?.intensity_blend?.weight ?? 0.2;
  const clampedIntensity = Math.max(0, Math.min(1, intensity));
  
  // Shift probability mass from clear toward caution/alert based on intensity
  const shift = blendWeight * clampedIntensity * logits.clear;
  logits.clear -= shift;
  logits.caution += shift * 0.6; // 60% to caution
  logits.alert += shift * 0.4;   // 40% to alert

  // Ensure no negative values after all adjustments
  logits.clear = Math.max(0, logits.clear);
  logits.caution = Math.max(0, logits.caution);
  logits.alert = Math.max(0, logits.alert);

  // Normalize back to distribution (sum = 1)
  const sum = Math.max(1e-9, logits.clear + logits.caution + logits.alert);
  const adjustedDist = {
    clear: logits.clear / sum,
    caution: logits.caution / sum,
    alert: logits.alert / sum,
  };

  logger.debug(`Attachment tone adjustment for ${style}:`, {
    context: ctx,
    intensity: clampedIntensity,
    baseDist,
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
    // No threshold shift, return original primary
    const entries = Object.entries(distribution) as [Bucket, number][];
    const primary = entries.sort((a, b) => b[1] - a[1])[0][0];
    return { primary, distribution };
  }

  const thresholdShift = ov.threshold_shift ?? cfg?.defaults?.threshold_shift ?? {};
  
  // Apply threshold shifts to create a "biased" distribution for tie-breaking
  const biased = {
    clear: distribution.clear - (Number(thresholdShift.clear) ?? 0),
    caution: distribution.caution - (Number(thresholdShift.caution) ?? 0),
    alert: distribution.alert - (Number(thresholdShift.alert) ?? 0),
  };

  // Find primary from biased distribution
  const entries = Object.entries(biased) as [Bucket, number][];
  const sortedEntries = entries.sort((a, b) => b[1] - a[1]);
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