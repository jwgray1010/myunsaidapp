// api/_lib/schemas/normalize.ts
import { suggestionResponseSchema } from './suggestionRequest';

type Bucket = 'clear' | 'caution' | 'alert';

function clamp01(n: unknown): number {
  const x = typeof n === 'number' ? n : Number(n);
  if (!isFinite(x)) return 0;
  return Math.max(0, Math.min(1, x));
}

function clampText(text: string, maxLength = 10000): string {
  if (typeof text !== 'string') return '';
  // Trim whitespace and clamp length for safety
  const trimmed = text.trim();
  return trimmed.length > maxLength ? trimmed.slice(0, maxLength) + '...' : trimmed;
}

function normalizeDist(input: unknown): Record<Bucket, number> {
  const fallback = { clear: 1 / 3, caution: 1 / 3, alert: 1 / 3 } as const;
  if (!input || typeof input !== 'object') return { ...fallback };

  const src = input as Record<string, unknown>;
  const raw = {
    clear: clamp01(src.clear),
    caution: clamp01(src.caution),
    alert: clamp01(src.alert),
  };

  // If everything is zero (or NaN → 0), return fallback to avoid div-by-zero
  const sum = raw.clear + raw.caution + raw.alert;
  if (sum <= 1e-9) return { ...fallback }; // epsilon check instead of <= 0

  // Normalize to sum=1
  const normalized = {
    clear: raw.clear / sum,
    caution: raw.caution / sum,
    alert: raw.alert / sum,
  };

  // Apply epsilon smoothing to prevent exactly zero probabilities
  const epsilon = 1e-6;
  const smoothed = {
    clear: Math.max(epsilon, normalized.clear),
    caution: Math.max(epsilon, normalized.caution),
    alert: Math.max(epsilon, normalized.alert),
  };

  // Re-normalize after epsilon application
  const smoothSum = smoothed.clear + smoothed.caution + smoothed.alert;
  return {
    clear: smoothed.clear / smoothSum,
    caution: smoothed.caution / smoothSum,
    alert: smoothed.alert / smoothSum,
  };
}

// Get the dominant tone bucket using arg-max with tie-breaking
function getArgMaxTone(distribution: Record<Bucket, number>): Bucket {
  const { clear, caution, alert } = distribution;
  
  // Find maximum value
  const maxVal = Math.max(clear, caution, alert);
  
  // Collect all buckets that achieve the maximum (for tie-breaking)
  const maxBuckets: Bucket[] = [];
  if (Math.abs(clear - maxVal) < 1e-9) maxBuckets.push('clear');
  if (Math.abs(caution - maxVal) < 1e-9) maxBuckets.push('caution');
  if (Math.abs(alert - maxVal) < 1e-9) maxBuckets.push('alert');
  
  // Deterministic tie-breaking: prefer caution > clear > alert for UI consistency
  if (maxBuckets.includes('caution')) return 'caution';
  if (maxBuckets.includes('clear')) return 'clear';
  return 'alert';
}

function pickTone(parsed: any, distribution?: Record<Bucket, number>): Bucket {
  // Prefer explicit UI tone; else try common backends; else use arg-max from distribution
  const explicitTone =
    parsed?.ui_tone ??
    parsed?.tone ??
    parsed?.primary_tone ??
    parsed?.primary_bucket;
    
  if (explicitTone) {
    const low = String(explicitTone).toLowerCase();
    if (low === 'clear' || low === 'caution' || low === 'alert') return low as Bucket;
  }
  
  // If no explicit tone but we have distribution, use arg-max
  if (distribution) {
    return getArgMaxTone(distribution);
  }
  
  // Final fallback
  return 'caution';
}

function buildOriginalAnalysis(parsed: any, uiTone: Bucket, distribution: Record<Bucket, number>) {
  // Prefer server-provided original_analysis if present
  if (parsed?.original_analysis && typeof parsed.original_analysis === 'object') {
    return {
      ...parsed.original_analysis,
      // Ensure required fields are present with safe defaults
      tone: parsed.original_analysis.tone ?? uiTone,
      sentiment: typeof parsed.original_analysis.sentiment === 'number' 
        ? clamp01(parsed.original_analysis.sentiment) 
        : 0.5,
      clarity_score: typeof parsed.original_analysis.clarity_score === 'number'
        ? clamp01(parsed.original_analysis.clarity_score)
        : 0.5,
      empathy_score: typeof parsed.original_analysis.empathy_score === 'number'
        ? clamp01(parsed.original_analysis.empathy_score)
        : 0.5,
      attachment_indicators: Array.isArray(parsed.original_analysis.attachment_indicators)
        ? parsed.original_analysis.attachment_indicators
        : [],
      communication_patterns: Array.isArray(parsed.original_analysis.communication_patterns)
        ? parsed.original_analysis.communication_patterns
        : [],
    };
  }

  // If we only have analysis_meta, synthesize a minimal-but-stable object
  const meta = parsed?.analysis_meta ?? {};
  const clarity =
    typeof meta.clarity_level === 'number' && isFinite(meta.clarity_level)
      ? clamp01(meta.clarity_level)
      : 0.5;

  const empathy =
    typeof meta.empathy_present === 'boolean'
      ? (meta.empathy_present ? 1 : 0)
      : 0.5; // Changed from 0 to 0.5 for neutral default

  const patterns = Array.isArray(meta.potential_triggers)
    ? meta.potential_triggers
    : [];

  // Enhanced fallback with distribution-informed sentiment
  const sentiment = distribution.clear > 0.5 ? 0.7 : 
                   distribution.alert > 0.5 ? 0.2 : 0.5;

  return {
    tone: uiTone,
    sentiment,
    clarity_score: clarity,
    empathy_score: empathy,
    attachment_indicators: [],
    communication_patterns: patterns,
    confidence: Math.max(distribution.clear, distribution.caution, distribution.alert), // Add confidence from distribution
  };
}

export function normalizeSuggestionResponse(raw: unknown) {
  // Be forgiving: never throw here. If it’s invalid, keep best-effort fallback.
  const result = suggestionResponseSchema.safeParse(raw);

  const parsed: any = result.success ? result.data : (raw ?? {});
  // Clamp and clean text input
  const text: string = clampText(
    (typeof parsed?.text === 'string' && parsed.text) ||
    (typeof parsed?.original_text === 'string' && parsed.original_text) ||
    ''
  );

  // Prefer UI distribution if present; else try 'buckets' (common backend shape); else fallback
  const ui_distribution = normalizeDist(
    parsed?.ui_distribution ?? parsed?.buckets ?? undefined
  );

  // Use distribution-aware tone picking
  const ui_tone = pickTone(parsed, ui_distribution);

  // Build stable original_analysis object with distribution context
  const original_analysis = buildOriginalAnalysis(parsed, ui_tone, ui_distribution);

  // Preserve everything the backend sent, but ensure our normalized fields override
  return {
    ...parsed,
    text,
    ui_tone,
    ui_distribution,
    original_analysis,
  };
}
