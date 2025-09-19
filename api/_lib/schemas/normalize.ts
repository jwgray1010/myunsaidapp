// api/_lib/schemas/normalize.ts
import { suggestionResponseSchema } from './suggestionRequest';

type Bucket = 'clear' | 'caution' | 'alert';

function clamp01(n: unknown): number {
  const x = typeof n === 'number' ? n : Number(n);
  if (!isFinite(x)) return 0;
  return Math.max(0, Math.min(1, x));
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
  if (sum <= 0) return { ...fallback };

  // Normalize to sum=1
  return {
    clear: raw.clear / sum,
    caution: raw.caution / sum,
    alert: raw.alert / sum,
  };
}

function pickTone(parsed: any): Bucket {
  // Prefer explicit UI tone; else try common backends; default to 'caution' (neutral-ish UI)
  const t =
    parsed?.ui_tone ??
    parsed?.tone ??
    parsed?.primary_tone ??
    parsed?.primary_bucket ??
    'caution';
  const low = String(t).toLowerCase();
  if (low === 'clear' || low === 'caution' || low === 'alert') return low as Bucket;
  return 'caution';
}

function buildOriginalAnalysis(parsed: any, uiTone: Bucket) {
  // Prefer server-provided original_analysis if present
  if (parsed?.original_analysis && typeof parsed.original_analysis === 'object') {
    return parsed.original_analysis;
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
      : 0;

  const patterns = Array.isArray(meta.potential_triggers)
    ? meta.potential_triggers
    : [];

  return {
    tone: uiTone,
    sentiment: 0,
    clarity_score: clarity,
    empathy_score: empathy,
    attachment_indicators: [],
    communication_patterns: patterns,
  };
}

export function normalizeSuggestionResponse(raw: unknown) {
  // Be forgiving: never throw here. If it’s invalid, keep best-effort fallback.
  const result = suggestionResponseSchema.safeParse(raw);

  const parsed: any = result.success ? result.data : (raw ?? {});
  const text: string =
    (typeof parsed?.text === 'string' && parsed.text) ||
    (typeof parsed?.original_text === 'string' && parsed.original_text) ||
    '';

  const ui_tone = pickTone(parsed);

  // Prefer UI distribution if present; else try 'buckets' (common backend shape); else fallback
  const ui_distribution = normalizeDist(
    parsed?.ui_distribution ?? parsed?.buckets ?? undefined
  );

  // Build stable original_analysis object
  const original_analysis = buildOriginalAnalysis(parsed, ui_tone);

  // Preserve everything the backend sent, but ensure our normalized fields override
  return {
    ...parsed,
    text,
    ui_tone,
    ui_distribution,
    original_analysis,
  };
}
