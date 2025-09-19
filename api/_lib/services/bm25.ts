// api/_lib/services/bm25.ts
type Doc = { id: string; text: string };
type Tokenizer = (s: string) => string[];

const defaultTok: Tokenizer = (s) => {
  // Unicode-safe, NFKC normalize, keep letters/numbers (any script)
  const norm = s.normalize('NFKC').toLowerCase();
  // Replace non-letter/number with space (unicode class)
  const cleaned = norm.replace(/[^\p{L}\p{N}\s]+/gu, ' ');
  return cleaned.split(/\s+/).filter(Boolean);
};

// Tiny Damerau-Levenshtein for fuzzy<=1 (fast path)
function dlDistanceLeq1(a: string, b: string): boolean {
  if (a === b) return true;
  const la = a.length, lb = b.length;
  const d = Math.abs(la - lb);
  if (d > 1) return false;
  // Same length → allow 1 substitution or 1 transposition
  if (la === lb) {
    let diff = 0;
    for (let i = 0; i < la; i++) if (a[i] !== b[i]) diff++;
    if (diff === 1) return true;
    // transposition
    for (let i = 0; i < la - 1; i++) {
      if (a[i] !== b[i] && a[i] === b[i+1] && a[i+1] === b[i]) {
        // ensure rest equal
        if (a.slice(i+2) === b.slice(i+2) && a.slice(0,i) === b.slice(0,i)) return true;
      }
    }
    return false;
  }
  // Length differs by 1 → insertion/deletion
  // Ensure shorter aligns with longer except one skip
  const s = la < lb ? a : b, t = la < lb ? b : a;
  let i = 0, j = 0, skipped = false;
  while (i < s.length && j < t.length) {
    if (s[i] === t[j]) { i++; j++; continue; }
    if (skipped) return false;
    skipped = true; j++; // skip one char in longer
  }
  return true;
}

export class BM25 {
  private docs: Doc[];
  private tok: Tokenizer;
  private df = new Map<string, number>();
  private tf = new Map<string, Map<string, number>>();
  private idfCache = new Map<string, number>();
  private N: number;
  private avgdl: number;
  private len = new Map<string, number>();
  private stop: Set<string>;
  private k1: number;
  private b: number;

  constructor(
    docs: Doc[],
    tok: Tokenizer = defaultTok,
    opts: { k1?: number; b?: number; stopwords?: string[] } = {}
  ) {
    this.docs = docs;
    this.tok = tok;
    this.k1 = opts.k1 ?? 1.2;
    this.b = opts.b ?? 0.75;
    this.stop = new Set((opts.stopwords ?? []).map(w => w.toLowerCase()));
    this.N = docs.length || 1;

    let totalLen = 0;
    for (const d of docs) {
      const terms = this.tok(d.text).filter(t => !this.stop.has(t));
      this.len.set(d.id, terms.length);
      totalLen += terms.length;

      const local = new Map<string, number>();
      for (const t of terms) local.set(t, (local.get(t) || 0) + 1);
      this.tf.set(d.id, local);

      for (const t of local.keys()) this.df.set(t, (this.df.get(t) || 0) + 1);
    }
    this.avgdl = totalLen / this.N || 1;

    // Precompute idf
    for (const [term, df] of this.df.entries()) {
      // BM25 idf: ln(1 + (N - df + 0.5)/(df + 0.5))
      this.idfCache.set(term, Math.log(1 + (this.N - df + 0.5) / (df + 0.5)));
    }
  }

  private idf(term: string) {
    const v = this.idfCache.get(term);
    if (v !== undefined) return v;
    // unseen term
    const df = this.df.get(term) || 0;
    const idf = Math.log(1 + (this.N - df + 0.5) / (df + 0.5));
    this.idfCache.set(term, idf);
    return idf;
  }

  // Helper: expand a query token into candidate index terms via prefix/fuzzy
  private expandTerm(qt: string, opts: { prefix?: boolean; fuzzy?: number }): string[] {
    const out: string[] = [];
    const { prefix = false, fuzzy = 0 } = opts;
    // Fast path: exact
    if (this.df.has(qt)) out.push(qt);

    // Prefix: scan df keys; cap to keep perf stable
    if (prefix) {
      let added = 0;
      for (const key of this.df.keys()) {
        if (key.startsWith(qt)) {
          out.push(key);
          if (++added >= 50) break; // safety cap
        }
      }
    }

    // Fuzzy radius 1 only (cheap), also capped
    if (fuzzy && fuzzy >= 1) {
      let added = 0;
      for (const key of this.df.keys()) {
        if (key === qt) continue;
        if (dlDistanceLeq1(qt, key)) {
          out.push(key);
          if (++added >= 50) break;
        }
      }
    }

    // de-dup
    return Array.from(new Set(out));
  }

  search(
    q: string,
    opts: { limit?: number; prefix?: boolean; fuzzy?: number } = {}
  ) {
    const { limit = 50, prefix = false, fuzzy = 0 } = opts;

    const raw = this.tok(q).filter(Boolean).filter(t => !this.stop.has(t));
    if (raw.length === 0) return [];

    // Build query terms with expansion map
    const expandedByQt = new Map<string, string[]>();
    for (const qt of raw) {
      expandedByQt.set(qt, this.expandTerm(qt, { prefix, fuzzy }));
    }

    const scores = new Map<string, number>();
    const matches = new Map<string, Set<string>>(); // for explainability

    for (const d of this.docs) {
      const tf = this.tf.get(d.id)!;
      const dl = this.len.get(d.id)!;
      let s = 0;

      for (const qt of raw) {
        const candidates = expandedByQt.get(qt)!;
        // Score the best candidate for this qt in this doc (avoids double-counting)
        let best = 0;
        let bestTerm: string | null = null;
        for (const t of candidates) {
          const f = tf.get(t) || 0;
          if (!f) continue;
          const idf = this.idf(t);
          const num = f * (this.k1 + 1);
          const den = f + this.k1 * (1 - this.b + (this.b * dl) / (this.avgdl || 1));
          const contrib = idf * (num / (den || 1));
          if (contrib > best) { best = contrib; bestTerm = t; }
        }
        if (best) {
          s += best;
          if (bestTerm) {
            if (!matches.has(d.id)) matches.set(d.id, new Set());
            matches.get(d.id)!.add(bestTerm);
          }
        }
      }

      if (s) scores.set(d.id, s);
    }

    return Array.from(scores.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([id, score]) => ({
        id,
        score,
        matchedTerms: Array.from(matches.get(id) || []),
      }));
  }
}
