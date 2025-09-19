/**
 * Integration adapter for weight_modifiers.json
 * 
 * This code needs to be integrated into toneAnalysis.ts to make
 * the alias/family resolution actually work.
 */

interface WeightModifiers {
  aliasMap?: Record<string, string>;
  familyMap?: Record<string, string>;
  fallbacks?: {
    envKillSwitch?: string;
    enabled?: boolean;
  };
  byContext?: Record<string, any>;
}

interface ResolveResult {
  key: string;
  reason: 'exact' | 'alias' | 'family' | 'fallback' | 'empty';
}

/**
 * Resolves context string to actual weight key using alias/family mapping
 * INSERT THIS into toneAnalysis.ts where weight resolution happens
 */
function resolveContextKey(ctxRaw: string, wm: WeightModifiers): ResolveResult {
  const ctx = (ctxRaw || '').toLowerCase().trim();
  if (!ctx) return { key: 'general', reason: 'empty' };

  // 1. Check alias map first (e.g., "work/school" → "work")
  const alias = wm.aliasMap?.[ctx];
  if (alias) return { key: alias, reason: 'alias' };

  // 2. Check family map for CTX_* patterns (e.g., "CTX_PLANNING" → "planning")
  if (/^ctx[_-]/i.test(ctx)) {
    const fam = wm.familyMap?.[ctx.toUpperCase()];
    if (fam) return { key: fam, reason: 'family' };
  }

  // 3. Check exact hit
  if (wm.byContext?.[ctx]) return { key: ctx, reason: 'exact' };

  // 4. Fallback to general
  return { key: 'general', reason: 'fallback' };
}

/**
 * Apply weight modifiers with proper resolution
 * REPLACE the existing _weights() logic in toneAnalysis.ts with this
 */
function applyWeightModifiers(baseWeights: any, context: string, wm: WeightModifiers): any {
  // Honor kill switch if set
  if (wm.fallbacks?.envKillSwitch && process.env[wm.fallbacks.envKillSwitch]) {
    console.log(`[WEIGHTS] Kill switch ${wm.fallbacks.envKillSwitch} active - skipping all weight mods`);
    return { ...baseWeights };
  }

  // Resolve context to actual key
  const { key, reason } = resolveContextKey(context, wm);
  
  // Get deltas for resolved key
  const deltas = wm.byContext?.[key] || {};
  
  // Apply deltas and clamp
  const result = { ...baseWeights };
  for (const [weightKey, delta] of Object.entries(deltas)) {
    if (typeof delta === 'number' && typeof result[weightKey] === 'number') {
      result[weightKey] = Math.max(0, Math.min(1, result[weightKey] + delta));
    }
  }

  // Log resolution for debugging
  console.log(`[WEIGHTS] ${context} → ${key} (${reason}) | deltas:`, deltas);
  
  return result;
}

/**
 * Test cases to verify integration works
 */
function testWeightResolution(wm: WeightModifiers) {
  console.log('\n=== Weight Resolution Tests ===');
  
  const testCases = [
    'work/school',      // should resolve via alias to "work"
    'CTX_PLANNING',     // should resolve via family to "planning"  
    'planning',         // should resolve exact
    'unknown_thing',    // should fallback to "general"
    '',                 // should default to "general"
  ];

  testCases.forEach(ctx => {
    const result = resolveContextKey(ctx, wm);
    console.log(`"${ctx}" → "${result.key}" (${result.reason})`);
  });
}

export { resolveContextKey, applyWeightModifiers, testWeightResolution };