// api/_lib/schemas/normalize.ts
import { suggestionResponseSchema } from './suggestionRequest';

type Bucket = 'clear' | 'caution' | 'alert';

type Dist = Record<Bucket, number>;

function clamp01(n: unknown): number {
  const x = typeof n === 'number' ? n : Number(n);
  if (!isFinite(x)) return 0;
  return Math.max(0, Math.min(1, x));
}

function clampText(text: any, maxLength = 10000): string {
  if (typeof text !== 'string') return '';
  const trimmed = text.trim();
  return trimmed.length > maxLength ? trimmed.slice(0, maxLength) + '...' : trimmed;
}

function safeObj<T extends object = Record<string, unknown>>(v: any): T {
  return (v && typeof v === 'object') ? (v as T) : ({} as T);
}

// Learning signals processing based on data/learning_signals.json patterns
function detectCommunicationPatterns(text: string): {
  patterns: string[];
  buckets: string[];
  scores: Record<string, number>;
  attachment_hints: Record<string, number>;
  noticings: string[];
} {
  if (!text || typeof text !== 'string') {
    return { patterns: [], buckets: [], scores: {}, attachment_hints: {}, noticings: [] };
  }
  
  const detectedPatterns: string[] = [];
  const detectedBuckets: Set<string> = new Set();
  const scores: Record<string, number> = {};
  const attachmentHints: Record<string, number> = {};
  const noticings: string[] = [];
  
  // Learning signals feature detection (key patterns from learning_signals.json)
  const features = [
    // Escalation patterns
    { id: 'absolutes', patterns: /\b(always|never|every time|nothing|no one|all the time)\b/gi, buckets: ['escalation_language'], toneWeights: { alert: 0.05, caution: 0.02 }, attachmentHints: { anxious: 0.02 }, noticing: 'Absolute language detected. Try softeners like "sometimes/this time."' },
    { id: 'threats', patterns: /\b(if|unless) you\b.*\b(then|i'm|i am) (done|leaving|out)\b|it's (me|this) or\b/gi, buckets: ['threats_ultimatums'], toneWeights: { alert: 0.08 }, noticing: 'Ultimatum detected. Consider a clear request + consequence later, not as a threat.' },
    { id: 'blame', patterns: /\b(it's your fault|because of you|you made me|you caused)\b/gi, buckets: ['blame_language'], toneWeights: { alert: 0.06 }, attachmentHints: { disorganized: 0.02 }, noticing: 'Blame tends to escalate. Try an I-statement about impact + a specific request.' },
    { id: 'invalidation', patterns: /\b(you're overreacting|calm down|it's not a big deal|get over it|move on)\b/gi, buckets: ['invalidation'], toneWeights: { alert: 0.05, caution: 0.02 }, noticing: 'Invalidation can shut things down. Try reflective language first.' },
    
    // Positive patterns  
    { id: 'repair', patterns: /\b(can we start over|how can we fix|that wasn't fair of me|i hear you)\b/gi, buckets: ['repair_language'], toneWeights: { clear: 0.06 }, attachmentHints: { secure: 0.04 }, noticing: 'Repair bid—great move. Keep it specific and time-bound.' },
    { id: 'validation', patterns: /\b(i see why you'd feel|it makes sense that|i can understand|what i hear you saying|so you're saying)\b/gi, buckets: ['validation_language'], toneWeights: { clear: 0.05 }, noticing: 'Validation detected. You are building safety—nice.' },
    { id: 'gratitude', patterns: /\b(thank you|i appreciate|that helped|means a lot)\b/gi, buckets: ['gratitude_language'], toneWeights: { clear: 0.04 }, noticing: 'Appreciation detected. Consider adding a concrete example for extra warmth.' },
    { id: 'i_statements', patterns: /\bi (feel|felt|am feeling)\b/gi, buckets: ['secure_expression'], toneWeights: { clear: 0.035 }, noticing: 'I-statement—healthy self-expression.' },
    { id: 'clear_requests', patterns: /\b(could we try|can we schedule|please (call|text) when|next time.*can we)\b/gi, buckets: ['clear_requests'], toneWeights: { clear: 0.045 }, noticing: 'Specific request—this improves outcomes. Add a timeframe if possible.' },
    
    // Withdrawal/avoidance patterns
    { id: 'withdrawal', patterns: /\b(forget it|never mind|doesn't matter|whatever|i don't want to talk about it|i'm done talking)\b/gi, buckets: ['withdrawal_language'], toneWeights: { caution: 0.03, alert: 0.04 }, attachmentHints: { avoidant: 0.03 }, noticing: 'Withdrawal phrases. A brief pause + scheduled revisit can keep connection.' },
    
    // Anxious attachment patterns
    { id: 'reassurance_seeking', patterns: /\b(do you still|are you sure|please just tell me|you promise|be honest.*(me|with me))\b/gi, buckets: ['reassurance'], toneWeights: { caution: 0.035 }, attachmentHints: { anxious: 0.05 }, noticing: 'Frequent reassurance-seeking. A quick validation first often calms the loop.' },
    { id: 'people_pleasing', patterns: /\b(its ok if not|no worries if not|i'm probably being.*(dramatic|too much))\b/gi, buckets: ['people_pleasing'], toneWeights: { caution: 0.025 }, attachmentHints: { anxious: 0.03 }, noticing: 'Self-minimizing. Your needs matter; try a direct, kind ask.' },
    
    // Safety and regulation patterns
    { id: 'safety_check', patterns: /\b(are you safe|is this safe|am i safe|do you feel safe|safety first)\b/gi, buckets: ['safety_check'], toneWeights: { clear: 0.05 }, noticing: 'Safety check—good. If the answer is no, pause content and route to safety guidance.' },
    { id: 'emotional_regulation', patterns: /\b(let's pause|i need a minute|i need (a|some) space|i need to calm down)\b/gi, buckets: ['emotional_regulation'], toneWeights: { clear: 0.04 }, noticing: 'Self-regulation detected—healthy boundary setting.' },
    { id: 'boundaries', patterns: /\bi need\b.*\b(space|minute|time|break)\b|i'll get back to you|not available|that doesn't work for me\b/gi, buckets: ['secure_boundary'], toneWeights: { clear: 0.05 }, attachmentHints: { secure: 0.03 }, noticing: 'Healthy boundary phrasing—clear ask + calm tone is effective.' },
  ];
  
  // Process each feature pattern
  for (const feature of features) {
    const matches = text.match(feature.patterns);
    if (matches && matches.length > 0) {
      detectedPatterns.push(feature.id);
      
      // Add buckets
      for (const bucket of feature.buckets) {
        detectedBuckets.add(bucket);
      }
      
      // Add tone weight scores  
      if (feature.toneWeights) {
        for (const [tone, weight] of Object.entries(feature.toneWeights)) {
          scores[tone] = (scores[tone] || 0) + weight;
        }
      }
      
      // Add attachment hints
      if (feature.attachmentHints) {
        for (const [style, hint] of Object.entries(feature.attachmentHints)) {
          attachmentHints[style] = (attachmentHints[style] || 0) + hint;
        }
      }
      
      // Add noticing
      if (feature.noticing) {
        noticings.push(feature.noticing);
      }
    }
  }
  
  return {
    patterns: detectedPatterns,
    buckets: Array.from(detectedBuckets),
    scores,
    attachment_hints: attachmentHints,
    noticings: noticings.slice(0, 3) // Max 3 noticings per message per learning_signals.json
  };
}

function normalizeDist(input: unknown): Dist {
  const fallback: Dist = { clear: 1 / 3, caution: 1 / 3, alert: 1 / 3 };
  if (!input || typeof input !== 'object') return { ...fallback };

  const src = input as Record<string, unknown>;
  const raw = {
    clear: clamp01(src.clear),
    caution: clamp01(src.caution),
    alert: clamp01(src.alert),
  };

  let sum = raw.clear + raw.caution + raw.alert;
  if (sum <= 1e-9) return { ...fallback };

  const normalized = {
    clear: raw.clear / sum,
    caution: raw.caution / sum,
    alert: raw.alert / sum,
  };

  // epsilon smoothing to avoid exact zeros
  const eps = 1e-6;
  const smoothed = {
    clear: Math.max(eps, normalized.clear),
    caution: Math.max(eps, normalized.caution),
    alert: Math.max(eps, normalized.alert),
  };

  sum = smoothed.clear + smoothed.caution + smoothed.alert;
  return {
    clear: smoothed.clear / sum,
    caution: smoothed.caution / sum,
    alert: smoothed.alert / sum,
  };
}

function argMaxTone(d: Dist): Bucket {
  const { clear, caution, alert } = d;
  const max = Math.max(clear, caution, alert);
  const near = (v: number) => Math.abs(v - max) < 1e-9;

  const ties: Bucket[] = [];
  if (near(caution)) ties.push('caution');
  if (near(clear)) ties.push('clear');
  if (near(alert)) ties.push('alert');

  // deterministic tie-breaker: caution > clear > alert for UI stability
  return ties[0];
}

function pickTone(parsed: any, distribution?: Dist): Bucket {
  const explicit =
    parsed?.ui_tone ??
    parsed?.tone ??
    parsed?.primary_tone ??
    parsed?.primary_bucket ??
    parsed?.original_analysis?.tone ??
    parsed?.toneAnalysis?.tone ??
    parsed?.toneAnalysis?.classification;

  if (explicit) {
    const low = String(explicit).toLowerCase();
    if (low === 'clear' || low === 'caution' || low === 'alert') {
      return low as Bucket;
    }
    // map common alternates
    if (low === 'angry' || low === 'hostile') return 'alert';
    if (low === 'sad' || low === 'frustrated') return 'caution';
  }

  if (distribution) return argMaxTone(distribution);
  return 'caution';
}

function mergeToneAliases(src: any) {
  // Accept both top-level and nested tone analysis shapes
  const oa = safeObj(src?.original_analysis);
  const ta = safeObj(src?.toneAnalysis);

  // unified view that prefers original_analysis then toneAnalysis then top-level
  const unified = {
    tone:
      oa.tone ??
      ta.tone ??
      ta.classification ??
      src.ui_tone ??
      src.tone ??
      src.primary_tone ??
      src.primary_bucket ??
      'caution',
    confidence:
      typeof oa.confidence === 'number' ? oa.confidence :
      typeof ta.confidence === 'number' ? ta.confidence :
      typeof src.confidence === 'number' ? src.confidence : 0.5,

    // distributions
    ui_distribution:
      src.ui_distribution ??
      oa.ui_distribution ??
      ta.ui_distribution ??
      src.buckets ??
      ta.buckets,

    // scores
    sentiment:
      (typeof oa.sentiment === 'number' ? oa.sentiment :
      typeof oa.sentiment_score === 'number' ? oa.sentiment_score :
      typeof ta.sentiment_score === 'number' ? ta.sentiment_score : undefined),
    intensity:
      (typeof oa.intensity === 'number' ? oa.intensity :
      typeof ta.intensity === 'number' ? ta.intensity : undefined),

    // features
    emotions: oa.emotions ?? ta.emotions,
    evidence: oa.evidence ?? ta.evidence,
    linguistic_features: oa.linguistic_features ?? ta.linguistic_features,
    context_analysis: oa.context_analysis ?? ta.context_analysis,

    // attachment & patterns (accept both names)
    attachment_indicators:
      oa.attachment_indicators ??
      oa.attachmentInsights ??
      ta.attachment_indicators ??
      ta.attachmentInsights ??
      [],
    communication_patterns:
      oa.communication_patterns ??
      ta.communication_patterns ??
      [],

    // ui helpers
    ui_tone: src.ui_tone ?? oa.ui_tone ?? ta.ui_tone,

    // meta
    metadata: oa.metadata ?? ta.metadata,
    tone_analysis_source:
      src.metadata?.tone_analysis_source ??
      src.tone_analysis_source ??
      oa.tone_analysis_source ??
      ta.tone_analysis_source,
    complete_analysis_available:
      !!(src.metadata?.complete_analysis_available ??
         src.complete_analysis_available ??
         oa.complete_analysis_available ??
         ta.complete_analysis_available),
  };

  return unified;
}

function buildOriginalAnalysis(parsed: any, uiTone: Bucket, dist: Dist) {
  const u = mergeToneAliases(parsed);

  // ✅ DETECT LEARNING SIGNALS from text
  const originalText = parsed?.text || parsed?.original_text || '';
  const learningSignals = detectCommunicationPatterns(originalText);

  // sentiment defaults guided by distribution
  const sentiment =
    typeof u.sentiment === 'number' ? u.sentiment :
    dist.clear > 0.5 ? 0.7 :
    dist.alert > 0.5 ? 0.2 : 0.5;

  // sensible defaults
  const clarity =
    typeof parsed?.original_analysis?.clarity_score === 'number'
      ? clamp01(parsed.original_analysis.clarity_score)
      : 0.5;

  const empathy =
    typeof parsed?.original_analysis?.empathy_score === 'number'
      ? clamp01(parsed.original_analysis.empathy_score)
      : 0.5;

  // ✅ MERGE COMMUNICATION PATTERNS from learning signals with existing patterns
  const existingPatterns = Array.isArray(u.communication_patterns) ? u.communication_patterns : [];
  const mergedPatterns = [...new Set([...existingPatterns, ...learningSignals.buckets])];
  
  // ✅ ENHANCE LINGUISTIC FEATURES with learning signal scores
  const enhancedLinguisticFeatures = {
    ...safeObj(u.linguistic_features),
    communication_patterns_detected: learningSignals.patterns,
    tone_adjustment_scores: learningSignals.scores,
    learning_signal_noticings: learningSignals.noticings,
  };
  
  // ✅ ENHANCE ATTACHMENT INDICATORS with learning signal hints
  const existingAttachmentIndicators = Array.isArray(u.attachment_indicators) ? u.attachment_indicators : [];
  const attachmentFromSignals = Object.keys(learningSignals.attachment_hints).filter(style => 
    learningSignals.attachment_hints[style] > 0.02 // Only include significant hints
  );
  const mergedAttachmentIndicators = [...new Set([...existingAttachmentIndicators, ...attachmentFromSignals])];

  return {
    // core tone fields
    tone: pickTone({ ui_tone: u.ui_tone, tone: u.tone }, dist),
    confidence: clamp01(u.confidence),

    // bucket helpers
    ui_tone: pickTone({ ui_tone: u.ui_tone, tone: u.tone }, dist),
    ui_distribution: dist,

    // emotion/sentiment/intensity
    sentiment,
    sentiment_score: sentiment,
    intensity: typeof u.intensity === 'number' ? clamp01(u.intensity) : 0.5,
    emotions: safeObj(u.emotions),

    // evidence & linguistic/context with learning signals enhancement
    evidence: u.evidence ?? [],
    linguistic_features: enhancedLinguisticFeatures,
    context_analysis: safeObj(u.context_analysis),

    // ✅ ENHANCED ATTACHMENT & PATTERNS with learning signals
    attachment_indicators: mergedAttachmentIndicators,
    attachmentInsights: mergedAttachmentIndicators, // Maintain dual naming for compatibility
    communication_patterns: mergedPatterns,

    // meta
    metadata: safeObj(u.metadata),
    tone_analysis_source:
      (typeof u.tone_analysis_source === 'string' ? u.tone_analysis_source : 'coordinator_cache') as
        'coordinator_cache' | 'fresh_analysis' | 'override',
    complete_analysis_available: !!u.complete_analysis_available,

    // ✅ ADD LEARNING SIGNALS DATA
    learning_signals: {
      patterns_detected: learningSignals.patterns,
      communication_buckets: learningSignals.buckets,
      attachment_hints: learningSignals.attachment_hints,
      tone_adjustments: learningSignals.scores,
      therapeutic_noticings: learningSignals.noticings,
    },

    // keep any extra fields the server might add in original_analysis
    ...(safeObj(parsed?.original_analysis)),
  };
}

function normalizeSuggestionItem(s: any, index: number) {
  const text = typeof s?.text === 'string' ? s.text :
               typeof s?.advice === 'string' ? s.advice : '';

  const category = ((): string => {
    const c = s?.category;
    const cats = Array.isArray(s?.categories) ? s.categories : [];
    const first = typeof c === 'string' ? c : (typeof cats[0] === 'string' ? cats[0] : undefined);
    // whitelist to keep schema happy
    const allowed = new Set(['emotional', 'practical', 'boundary', 'clarity', 'repair', 'general']);
    return allowed.has(String(first)) ? String(first) : 'emotional';
  })();

  const cats = Array.isArray(s?.categories) && s.categories.length
    ? s.categories
    : [category];

  return {
    id: String(s?.id ?? index + 1),
    text: clampText(text, 2000),
    type: ((): 'advice' | 'rewrite' | 'note' => {
      const t = String(s?.type ?? 'advice').toLowerCase();
      return (t === 'rewrite' || t === 'note') ? (t as any) : 'advice';
    })(),
    confidence: clamp01(typeof s?.confidence === 'number' ? s.confidence : 0.55),
    reason: typeof s?.reason === 'string'
      ? s.reason
      : 'Therapeutic advice based on tone + context',
    category,
    categories: cats,
    priority: Number.isFinite(s?.priority) ? Number(s.priority) : 1,
    context_specific: Boolean(s?.context_specific ?? true),
    attachment_informed: Boolean(s?.attachment_informed ?? true),

    // pass through any extra keys the engine may add
    ...safeObj(s),
  };
}

export function normalizeSuggestionResponse(raw: unknown) {
  // Never throw: validate, then best-effort normalize
  const parsedResult = suggestionResponseSchema.safeParse(raw);
  const parsed: any = parsedResult.success ? parsedResult.data : (raw ?? {});

  // Text fields
  const text =
    clampText(
      (typeof parsed?.text === 'string' && parsed.text) ||
      (typeof parsed?.original_text === 'string' && parsed.original_text) ||
      ''
    );
  const original_text =
    clampText(
      (typeof parsed?.original_text === 'string' && parsed.original_text) ||
      (typeof parsed?.text === 'string' && parsed.text) ||
      ''
    );

  // Distribution & ui_tone
  const ui_distribution = normalizeDist(
    parsed?.ui_distribution ??
    parsed?.buckets ??
    parsed?.original_analysis?.ui_distribution ??
    parsed?.toneAnalysis?.ui_distribution
  );
  const ui_tone = pickTone(parsed, ui_distribution);

  // Original analysis (rich, tone-first)
  const original_analysis = buildOriginalAnalysis(parsed, ui_tone, ui_distribution);

  // Suggestions (normalize minimally but safely)
  const suggestionsRaw: any[] = Array.isArray(parsed?.suggestions) ? parsed.suggestions : [];
  const suggestions = suggestionsRaw.map(normalizeSuggestionItem);

  // carry through common top-level fields while ensuring normalized ones win
  const base = {
    ...safeObj(parsed),
    text,
    original_text,
    ui_tone,
    ui_distribution,
    original_analysis,
    suggestions,
  };

  // Light-touch metadata normalization - handle case where metadata might not exist
  const meta = safeObj((base as any).metadata);
  (base as any).metadata = {
    ...meta,
    processingTimeMs: Number.isFinite(meta.processingTimeMs) ? Number(meta.processingTimeMs) : meta.processingTimeMs,
    model_version: typeof meta.model_version === 'string' ? meta.model_version : ((base as any).version ?? 'v1.0.0-advanced'),
    tone_analysis_source:
      (original_analysis.tone_analysis_source ??
       meta.tone_analysis_source ??
       'coordinator_cache') as 'coordinator_cache' | 'fresh_analysis' | 'override',
    complete_analysis_available:
      typeof meta.complete_analysis_available === 'boolean'
        ? meta.complete_analysis_available
        : !!original_analysis.complete_analysis_available,
    
    // ✅ ADD LEARNING SIGNALS METADATA
    learning_signals_processed: original_analysis.learning_signals?.patterns_detected?.length > 0,
    communication_patterns_count: original_analysis.learning_signals?.communication_buckets?.length || 0,
    therapeutic_noticings_count: original_analysis.learning_signals?.therapeutic_noticings?.length || 0,
  };

  // Safety net: ensure distribution is finite at the boundary
  const b = base.ui_distribution as Dist;
  if (![b.clear, b.caution, b.alert].every(Number.isFinite)) {
    base.ui_distribution = normalizeDist({ clear: 1, caution: 0, alert: 0 });
  }

  return base;
}
