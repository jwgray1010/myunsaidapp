// api/_lib/schemas/normalize.ts
import { suggestionResponseSchema } from './suggestionRequest';

export function normalizeSuggestionResponse(raw: unknown) {
  const parsed = suggestionResponseSchema.parse(raw);

  const text = parsed.text ?? parsed.original_text ?? '';
  const ui_tone = parsed.ui_tone;
  // Ensure ui_distribution fallback is always set if missing
  const ui_distribution = parsed.ui_distribution ?? { clear: 1/3, caution: 1/3, alert: 1/3 };

  // Build a best-effort "original_analysis" if backend only sent analysis_meta
  const original_analysis = parsed.original_analysis ?? (parsed.analysis_meta ? {
    tone: ui_tone ?? 'caution',
    sentiment: 0,
    clarity_score: typeof (parsed as any)?.analysis_meta?.clarity_level === 'number'
      ? (parsed as any).analysis_meta.clarity_level : 0.5,
    empathy_score: (parsed as any)?.analysis_meta?.empathy_present ? 1 : 0,
    attachment_indicators: [],
    communication_patterns: Array.isArray((parsed as any)?.analysis_meta?.potential_triggers)
      ? (parsed as any).analysis_meta.potential_triggers : [],
  } : undefined);

  return {
    ...parsed,
    text,
    original_analysis,
    ui_tone,
    ui_distribution,
  };
}