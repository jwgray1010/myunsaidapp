// api/_lib/utils/foldAttachmentPatterns.ts
export function foldAttachmentPatterns(
  base: Record<string, number>,
  est: { confidence: number; scores: { anxious:number; avoidant:number; disorganized:number; secure:number } },
  phraseEdgeHints?: Array<'attachment_triggers'|'codependency_patterns'|'independence_patterns'> // optional
) {
  const out = { ...base };
  const conf = Math.max(0, Math.min(1, est?.confidence ?? 0));
  const gain = 0.75 * conf;
  const floor = 0.15 * conf;

  const lift = (k: string, v: number) => {
    const cur = Number(out[k] || 0);
    out[k] = Math.max(cur, floor + (v || 0) * gain);
  };

  lift('anxious.pattern',      est?.scores?.anxious ?? 0);
  lift('avoidant.pattern',     est?.scores?.avoidant ?? 0);
  lift('disorganized.pattern', est?.scores?.disorganized ?? 0);
  lift('secure.pattern',       est?.scores?.secure ?? 0);

  // small runtime nudges from phrase_edges (capped)
  if (phraseEdgeHints?.includes('attachment_triggers')) out['anxious.pattern']      = Math.min(1, (out['anxious.pattern']||0) + 0.05);
  if (phraseEdgeHints?.includes('codependency_patterns')) out['anxious.pattern']    = Math.min(1, (out['anxious.pattern']||0) + 0.03);
  if (phraseEdgeHints?.includes('independence_patterns')) out['avoidant.pattern']   = Math.min(1, (out['avoidant.pattern']||0) + 0.05);

  return out;
}