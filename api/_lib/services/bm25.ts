// api/_lib/services/bm25.ts
type Doc = { id: string; text: string };
type Tokenizer = (s: string) => string[];

const defaultTok: Tokenizer = (s) =>
  s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean);

export class BM25 {
  private docs: Doc[];
  private tok: Tokenizer;
  private df = new Map<string, number>();
  private tf = new Map<string, Map<string, number>>();
  private N: number;
  private avgdl: number;
  private k1 = 1.2;
  private b = 0.75;
  private len = new Map<string, number>();

  constructor(docs: Doc[], tok: Tokenizer = defaultTok) {
    this.docs = docs;
    this.tok = tok;
    this.N = docs.length || 1;
    let totalLen = 0;

    for (const d of docs) {
      const terms = this.tok(d.text);
      this.len.set(d.id, terms.length);
      totalLen += terms.length;

      const local = new Map<string, number>();
      for (const t of terms) local.set(t, (local.get(t) || 0) + 1);
      this.tf.set(d.id, local);

      for (const t of local.keys()) this.df.set(t, (this.df.get(t) || 0) + 1);
    }
    this.avgdl = totalLen / this.N || 1;
  }

  private idf(term: string) {
    const df = this.df.get(term) || 0;
    return Math.log(1 + (this.N - df + 0.5) / (df + 0.5));
  }

  search(q: string, opts: { limit?: number; prefix?: boolean; fuzzy?: number } = {}) {
    const { limit = 50 } = opts;
    const qterms = this.tok(q);
    const scores = new Map<string, number>();

    for (const d of this.docs) {
      const tf = this.tf.get(d.id)!;
      const dl = this.len.get(d.id)!;
      let s = 0;
      for (const t of qterms) {
        const f = tf.get(t) || 0;
        if (!f) continue;
        const idf = this.idf(t);
        const num = f * (this.k1 + 1);
        const den = f + this.k1 * (1 - this.b + (this.b * dl) / this.avgdl);
        s += idf * (num / (den || 1));
      }
      if (s) scores.set(d.id, s);
    }

    return [...scores.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([id, score]) => ({ id, score }));
  }
}