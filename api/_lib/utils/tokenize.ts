/**
 * Shared tokenizer utility for consistent Unicode/emoji-aware tokenization
 * Used across spaCy client, BM25 retrieval, and other text processing
 * 
 * Ensures tokens match between analysis and retrieval for proper alignment
 */

/**
 * Unicode/emoji-aware tokenization with NFKC normalization
 * Splits on word boundaries while preserving emojis as single tokens
 * @param text - Input text to tokenize
 * @returns Array of tokens (emojis, words, numbers preserved)
 */
export function tokenize(text: string): string[] {
  return (text
    .normalize('NFKC')
    .toLowerCase()
    .split(/\s+/)
    .filter(word => word.length > 0 && /[a-zA-ZÀ-ÿĀ-žА-я\u4e00-\u9fff\d]/.test(word)));
}

/**
 * Default stopwords list aligned with spaCy client
 * Small, focused list to avoid over-filtering in sensitive contexts
 */
export const DEFAULT_STOPWORDS = new Set([
  'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by', 'from', 'as', 'that', 'this'
]);

/**
 * Filter tokens through stopword list
 * @param tokens - Array of tokens to filter
 * @param stopwords - Set of stopwords to remove (defaults to DEFAULT_STOPWORDS)
 * @returns Filtered token array
 */
export function filterStopwords(tokens: string[], stopwords: Set<string> = DEFAULT_STOPWORDS): string[] {
  return tokens.filter(token => !stopwords.has(token));
}

/**
 * Tokenize and filter stopwords in one call
 * @param text - Input text to process
 * @param stopwords - Optional custom stopword set
 * @returns Array of filtered tokens
 */
export function tokenizeAndFilter(text: string, stopwords?: Set<string>): string[] {
  return filterStopwords(tokenize(text), stopwords);
}

/**
 * Optional accent folding for normalization parity
 * Strips diacritics for broader matching
 * @param text - Input text
 * @returns Text with diacritics removed
 */
export function foldAccents(text: string): string {
  return text.normalize('NFD').replace(/[\u0300-\u036f]+/g, '');
}