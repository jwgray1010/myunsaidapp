// api/_lib/services/p-classifier.ts
// Zero-shot + rules → unified P-scores for therapy advice classification

import { logger } from '../logger';
import { ALL_P, P_MAP, RULE_SEEDS, P_DESCRIPTIONS, P_PATTERNS, type PCode } from './p-taxonomy';

// For serverless/Vercel environment, we'll use a simpler rule-based approach initially
// TODO: Add @xenova/transformers for zero-shot when needed in client-side or dedicated service

export interface ClassificationOptions {
  threshold?: number;
  usePatterns?: boolean;
  useKeywords?: boolean;
}

export interface ClassificationResult {
  p_scores: Record<PCode, number>;
  ruleScores: Record<PCode, number>;
  mlScores: Record<PCode, number>;
  method: 'enhanced_rules' | 'zero_shot' | 'hybrid';
  error?: string;
}

export interface PCodeExplanation {
  code: PCode;
  description: string;
  score: number;
  matchedRules: string[];
}

const LABEL_VERBALIZATIONS: Record<PCode, string> = Object.fromEntries(
  ALL_P.map((p) => [
    p,
    // Short, plain-English render for zero-shot
    P_MAP[p].replace(/_/g, " "),
  ])
) as Record<PCode, string>;

/**
 * Simple rule-based hit scorer using keyword matching
 * @param text - Input text to analyze
 * @returns Scores for each P-code
 */
function keywordScore(text: string): Record<PCode, number> {
  const t = text.toLowerCase();
  const scores = Object.fromEntries(ALL_P.map((p) => [p, 0])) as Record<PCode, number>;
  
  for (const p of ALL_P) {
    for (const phrase of RULE_SEEDS[p] || []) {
      if (t.includes(phrase)) {
        scores[p] += 0.15; // Base boost per keyword hit
      }
    }
  }
  
  return scores;
}

/**
 * Enhanced rule scorer with pattern matching
 * @param text - Input text to analyze
 * @returns Enhanced scores for each P-code
 */
function patternScore(text: string): Record<PCode, number> {
  const scores = Object.fromEntries(ALL_P.map((p) => [p, 0])) as Record<PCode, number>;
  
  // Apply pattern matching
  for (const p of ALL_P) {
    for (const pattern of P_PATTERNS[p] || []) {
      if (pattern.test(text)) {
        scores[p] += 0.3; // Higher boost for pattern matches
      }
    }
  }
  
  return scores;
}

/**
 * Get detailed matching information for debugging
 * @param text - Input text
 * @param pCode - P-code to analyze
 * @returns Matched rules and patterns
 */
function getMatchDetails(text: string, pCode: PCode): string[] {
  const matches: string[] = [];
  const t = text.toLowerCase();
  
  // Check keyword matches
  for (const phrase of RULE_SEEDS[pCode] || []) {
    if (t.includes(phrase)) {
      matches.push(`keyword: "${phrase}"`);
    }
  }
  
  // Check pattern matches
  for (const pattern of P_PATTERNS[pCode] || []) {
    if (pattern.test(text)) {
      matches.push(`pattern: ${pattern.source}`);
    }
  }
  
  return matches;
}

/**
 * Merge two score maps
 * @param a - First score map
 * @param b - Second score map
 * @returns Merged scores
 */
function mergeScores(
  a: Record<PCode, number>, 
  b: Record<PCode, number>
): Record<PCode, number> {
  const out = {} as Record<PCode, number>;
  for (const p of ALL_P) {
    out[p] = (a[p] || 0) + (b[p] || 0);
  }
  return out;
}

/**
 * Main P-code classification function
 * @param text - Text to classify
 * @param options - Classification options
 * @returns Classification results
 */
export async function classifyP(
  text: string, 
  options: ClassificationOptions = {}
): Promise<ClassificationResult> {
  const { threshold = 0.45, usePatterns = true, useKeywords = true } = options;
  
  try {
    if (!text || typeof text !== 'string') {
      throw new Error('Text input is required and must be a string');
    }
    
    let ruleScores = Object.fromEntries(ALL_P.map((p) => [p, 0])) as Record<PCode, number>;
    
    // Apply keyword scoring if enabled
    if (useKeywords) {
      const keywordScores = keywordScore(text);
      ruleScores = mergeScores(ruleScores, keywordScores);
    }
    
    // Apply pattern scoring if enabled
    if (usePatterns) {
      const patternScores = patternScore(text);
      ruleScores = mergeScores(ruleScores, patternScores);
    }
    
    // Apply threshold filtering
    const p_scores = Object.fromEntries(
      Object.entries(ruleScores).filter(([, s]) => s >= threshold)
    ) as Record<PCode, number>;
    
    logger.debug('[P-Classifier] Classification results', {
      text: text.substring(0, 100) + (text.length > 100 ? '...' : ''),
      p_scores,
      threshold,
      total_matches: Object.keys(p_scores).length
    });
    
    return { 
      p_scores, 
      ruleScores,
      mlScores: {} as Record<PCode, number>, // Placeholder for future ML scores
      method: 'enhanced_rules'
    };
    
  } catch (error) {
    logger.error('[P-Classifier] Classification failed', { 
      error: (error as Error).message, 
      text: text?.substring(0, 50) 
    });
    return { 
      p_scores: {} as Record<PCode, number>, 
      ruleScores: {} as Record<PCode, number>, 
      mlScores: {} as Record<PCode, number>,
      method: 'enhanced_rules',
      error: (error as Error).message 
    };
  }
}

/**
 * Get human-readable explanation of P-codes with match details
 * @param text - Original text that was classified
 * @param pCodes - P-codes to explain
 * @returns Detailed explanations for each P-code
 */
export function explainPCodes(text: string, pCodes: PCode[]): PCodeExplanation[] {
  return pCodes.map(p => ({
    code: p,
    description: P_DESCRIPTIONS[p] || `Unknown P-code: ${p}`,
    score: 0, // This would be filled by the caller with actual scores
    matchedRules: getMatchDetails(text, p)
  }));
}

/**
 * Get all available P-codes with their descriptions
 * @returns Map of P-codes to descriptions
 */
export function getAllPCodes(): Record<PCode, string> {
  return { ...P_DESCRIPTIONS };
}