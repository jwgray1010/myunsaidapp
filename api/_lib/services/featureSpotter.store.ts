// api/_lib/services/featureSpotter.store.ts
import { dataLoader } from './dataLoader';
import { logger } from '../logger';
import type { FSConfig, FSRunResult, FSMatch } from '../types/featureSpotter';

export class FeatureSpotterStore {
  constructor(private userId: string) {}

  private cfg(): FSConfig {
    const cfg = dataLoader.getFeatureSpotter();
    if (!cfg) throw new Error('feature_spotter.json not loaded');
    return cfg as FSConfig;
  }

  run(text: string, deps: { hasNegation?: boolean; hasSarcasm?: boolean; }): FSRunResult {
    const cfg = this.cfg();
    const t = (text || '').slice(0, cfg.globals.maxInputChars);
    const flags = cfg.globals.flags || 'i';

    const cache = (FeatureSpotterStore as any)._rxCache ?? ((FeatureSpotterStore as any)._rxCache = new Map<string, RegExp>());
    const rx = (p: string) => {
      const key = `${flags}::${p}`;
      if (!cache.has(key)) cache.set(key, new RegExp(p, flags));
      return cache.get(key)!;
    };

    const matches: FSMatch[] = [];
    const toneHints: Record<'clear'|'caution'|'alert', number> = { clear: 0, caution: 0, alert: 0 };
    const attachmentHints: Record<string, number> = { anxious:0, avoidant:0, disorganized:0, secure:0 };
    let intensityHints = 0;

    logger.info('FeatureSpotter analysis started', { 
      userId: this.userId,
      textLength: t.length, 
      featureCount: cfg.features.length 
    });

    for (const f of cfg.features) {
      const found: string[] = [];
      for (const p of f.patterns) {
        try {
          const m = t.match(rx(p));
          if (m) found.push(...m.slice(0, cfg.globals.matchLimitPerFeature));
        } catch (error) {
          logger.warn('Feature pattern match failed', { 
            featureId: f.id, 
            pattern: p, 
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
      if (!found.length) continue;

      logger.info('Feature pattern matched', {
        featureId: f.id,
        matchCount: found.length,
        matches: found.slice(0, 3) // Log first 3 matches
      });

      // tone and attachment nudges
      Object.entries(f.weights ?? {}).forEach(([k, v]) => {
        if (k.startsWith('tone.')) {
          const key = k.split('.')[1] as 'clear'|'caution'|'alert';
          toneHints[key] = (toneHints[key] ?? 0) + v;
        }
      });
      Object.entries(f.attachmentHints ?? {}).forEach(([style, val]) => {
        attachmentHints[style] = (attachmentHints[style] ?? 0) + val;
      });

      if (f.buckets.includes('escalation_language')) intensityHints += 0.05 * found.length;

      for (const b of f.buckets) {
        matches.push({
          featureId: f.id,
          bucket: b,
          matches: Array.from(new Set(found)),
          weight: (cfg.scoringDefaults.baseWeight || 0.01)
        });
      }
    }

    // Apply co-occurrence boosts
    if (deps?.hasNegation) {
      const boost = cfg.scoringDefaults.cooccurrenceBoost.withNegation || 0;
      toneHints.caution += boost;
      logger.info('Negation co-occurrence boost applied', { boost });
    }
    if (deps?.hasSarcasm) {
      const boost = cfg.scoringDefaults.cooccurrenceBoost.withSarcasm || 0;
      toneHints.caution += boost;
      logger.info('Sarcasm co-occurrence boost applied', { boost });
    }

    // choose a few noticings for UX
    const counts = new Map<string, number>();
    matches.forEach(m => counts.set(m.bucket, (counts.get(m.bucket) ?? 0) + 1));
    const top = Array.from(counts.entries()).sort((a,b)=>b[1]-a[1]).slice(0, cfg.runtime.conflictResolution.maxNoticingsPerMessage);
    const noticings = top
      .map(([bucket]) => cfg.noticingsMap[bucket])
      .filter(Boolean)
      .map((msg, i) => ({ bucket: top[i][0], message: msg }));

    const result = { 
      noticings, 
      matches, 
      intensityHints: Math.min(1, intensityHints), 
      attachmentHints, 
      toneHints 
    };

    logger.info('FeatureSpotter analysis completed', {
      userId: this.userId,
      matchesCount: matches.length,
      noticingsCount: noticings.length,
      intensityHints: result.intensityHints,
      toneHints,
      attachmentHints
    });

    return result;
  }

  /** Optional: nudge your CommunicatorProfile.learningSignals */
  aggregateToProfile(run: FSRunResult, profile: any) {
    if (!profile) {
      logger.warn('No profile provided for FeatureSpotter aggregation', { userId: this.userId });
      return;
    }

    const cfg = this.cfg();
    const now = Date.now();
    const signals = (profile?.getLearningSignals?.() ?? {}) as Record<string, any>;
    
    let aggregatedCount = 0;
    (run.matches || []).forEach(m => {
      const key = m.bucket; // e.g. escalation_language
      const cd = cfg.aggregation.cooldownMsPerBucket[key] ?? 0;
      const lastAt = (signals.__cooldowns?.[key] ?? 0) as number;
      if (now - lastAt < cd) {
        logger.debug('FeatureSpotter signal skipped due to cooldown', {
          bucket: key,
          cooldownMs: cd,
          timeSinceLastMs: now - lastAt
        });
        return;
      }
      signals[key] = Number(signals[key] || 0) + m.weight;
      signals.__cooldowns = signals.__cooldowns || {};
      signals.__cooldowns[key] = now;
      aggregatedCount++;
    });
    
    // write back to profile memory (mirrors your existing pattern)
    if (profile && (profile as any).data?.learningSignals) {
      (profile as any).data.learningSignals = { ...(profile as any).data.learningSignals, ...signals };
    }

    logger.info('FeatureSpotter signals aggregated to profile', {
      userId: this.userId,
      signalsProcessed: run.matches.length,
      signalsAggregated: aggregatedCount,
      skippedDueToCooldown: run.matches.length - aggregatedCount
    });
  }
}