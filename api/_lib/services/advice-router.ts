// api/_lib/services/advice-router.ts
// P-code based therapy advice routing and selection

import { logger } from '../logger';
import { classifyP, type ClassificationOptions } from './p-classifier';
import { type PCode } from './p-taxonomy';
import type { TherapyAdvice } from '../types/dataTypes';

export interface AdviceRouterOptions extends ClassificationOptions {
  tone?: string;
  context?: string;
  maxResults?: number;
  includeScores?: boolean;
}

export interface ScoredAdvice {
  score: number;
  item: TherapyAdvice;
  matchedPCodes: PCode[];
  explanation?: string;
}

export interface AdviceRouterResult {
  p_scores: Record<PCode, number>;
  top: TherapyAdvice[];
  scored?: ScoredAdvice[];
  total_candidates: number;
  classification_method: string;
}

/**
 * Calculate base score for therapy advice based on P-code matches
 * @param advice - Therapy advice item
 * @param pScores - P-code classification scores
 * @returns Base score and matched P-codes
 */
function calculateBaseScore(
  advice: TherapyAdvice, 
  pScores: Record<PCode, number>
): { score: number; matchedPCodes: PCode[] } {
  const linked = (advice.spacyLink || []) as PCode[];
  const matchedPCodes: PCode[] = [];
  
  if (linked.length === 0) {
    return { score: 0, matchedPCodes };
  }
  
  let maxScore = 0;
  for (const pCode of linked) {
    const pScore = pScores[pCode] || 0;
    if (pScore > 0) {
      matchedPCodes.push(pCode);
      maxScore = Math.max(maxScore, pScore);
    }
  }
  
  return { score: maxScore, matchedPCodes };
}

/**
 * Apply contextual bonuses to advice score
 * @param advice - Therapy advice item
 * @param baseScore - Base P-code score
 * @param tone - Current tone context
 * @param context - Current conversation context
 * @returns Enhanced score with bonuses applied
 */
function applyContextualBonuses(
  advice: TherapyAdvice,
  baseScore: number,
  tone?: string,
  context?: string
): number {
  let score = baseScore;
  
  // Tone matching bonus
  if (tone && advice.triggerTone && advice.triggerTone.includes(tone as any)) {
    score += 0.05;
  }
  
  // Context matching bonus
  if (context && (advice.contexts || []).includes(context)) {
    score += 0.05;
  }
  
  // Multiple context matches (progressive bonus)
  if (context && advice.contexts) {
    const contextMatches = advice.contexts.filter(ctx => ctx === context).length;
    if (contextMatches > 1) {
      score += 0.02 * (contextMatches - 1);
    }
  }
  
  return score;
}

/**
 * Check if advice meets severity threshold requirements
 * @param advice - Therapy advice item
 * @param score - Calculated score
 * @returns Whether advice meets threshold
 */
function meetsSeverityThreshold(advice: TherapyAdvice, score: number): boolean {
  if (!advice.severityThreshold) {
    return true; // No threshold means always eligible
  }
  
  // Check if any severity threshold is met
  const thresholds = Object.values(advice.severityThreshold);
  if (thresholds.length === 0) {
    return true;
  }
  
  // Use the lowest threshold as the requirement
  const minThreshold = Math.min(...thresholds);
  return score >= minThreshold;
}

/**
 * Generate explanation for why advice was selected
 * @param advice - Therapy advice item
 * @param matchedPCodes - P-codes that matched
 * @param score - Final score
 * @returns Human-readable explanation
 */
function generateExplanation(
  advice: TherapyAdvice,
  matchedPCodes: PCode[],
  score: number
): string {
  const parts: string[] = [];
  
  if (matchedPCodes.length > 0) {
    parts.push(`Matched P-codes: ${matchedPCodes.join(', ')}`);
  }
  
  if (advice.contexts && advice.contexts.length > 0) {
    parts.push(`Contexts: ${advice.contexts.join(', ')}`);
  }
  
  parts.push(`Score: ${score.toFixed(3)}`);
  
  return parts.join(' | ');
}

/**
 * Main advice selection function based on P-code classification
 * @param text - Input text to analyze
 * @param adviceItems - Array of therapy advice items
 * @param options - Router options
 * @returns Advice routing results
 */
export async function pickAdvice(
  text: string,
  adviceItems: TherapyAdvice[],
  options: AdviceRouterOptions = {}
): Promise<AdviceRouterResult> {
  const { 
    tone, 
    context, 
    maxResults = 5, 
    includeScores = false,
    ...classificationOptions 
  } = options;
  
  try {
    // Classify text to get P-code scores
    const { p_scores, method } = await classifyP(text, classificationOptions);
    
    if (Object.keys(p_scores).length === 0) {
      logger.debug('[AdviceRouter] No P-codes matched for text', { 
        text: text.substring(0, 50) 
      });
      return {
        p_scores,
        top: [],
        total_candidates: 0,
        classification_method: method
      };
    }
    
    // Score and filter advice items
    const scored: ScoredAdvice[] = [];
    
    for (const advice of adviceItems) {
      const { score: baseScore, matchedPCodes } = calculateBaseScore(advice, p_scores);
      
      if (baseScore === 0) continue; // No P-code matches
      
      // Apply contextual bonuses
      const enhancedScore = applyContextualBonuses(advice, baseScore, tone, context);
      
      // Check severity threshold
      if (!meetsSeverityThreshold(advice, enhancedScore)) continue;
      
      const scoredAdvice: ScoredAdvice = {
        score: enhancedScore,
        item: advice,
        matchedPCodes
      };
      
      if (includeScores) {
        scoredAdvice.explanation = generateExplanation(advice, matchedPCodes, enhancedScore);
      }
      
      scored.push(scoredAdvice);
    }
    
    // Sort by score (descending) and limit results
    scored.sort((a, b) => b.score - a.score);
    const topScored = scored.slice(0, maxResults);
    
    logger.debug('[AdviceRouter] Advice selection completed', {
      total_candidates: scored.length,
      returned_count: topScored.length,
      top_score: topScored[0]?.score || 0,
      p_codes_matched: Object.keys(p_scores)
    });
    
    const result: AdviceRouterResult = {
      p_scores,
      top: topScored.map(s => s.item),
      total_candidates: scored.length,
      classification_method: method
    };
    
    if (includeScores) {
      result.scored = topScored;
    }
    
    return result;
    
  } catch (error) {
    logger.error('[AdviceRouter] Advice selection failed', {
      error: (error as Error).message,
      text: text?.substring(0, 50)
    });
    
    return {
      p_scores: {} as Record<PCode, number>,
      top: [],
      total_candidates: 0,
      classification_method: 'error'
    };
  }
}