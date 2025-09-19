// api/_lib/services/utils/semanticBackbone.ts
// Semantic backbone matching and analysis using semantic_thesaurus.json

import { dataLoader } from '../dataLoader';

export interface SemanticMatch {
  cluster: string;
  strength: number;
  matchedTerms: string[];
}

export interface SemanticClusterData {
  patterns?: string[];
  keywords?: string[];
  phrases?: string[];
  confidence_calibration?: number;
  context_bias?: Record<string, number>;
  tone_bias?: Record<string, number>;
}

export interface SemanticThesaurus {
  clusters?: Record<string, SemanticClusterData>;
  routing_matrix?: Record<string, Record<string, number>>;
  attachment_overrides?: Record<string, Record<string, string>>;
}

export interface SemanticBackboneResult {
  primaryCluster: string | null;
  allMatches: SemanticMatch[];
  routingBias: string | null;
  contextShift: Record<string, number>;
  attachmentOverride: string | null;
}

// Helper functions for serverless-safe processing
function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}

function sat(n: number, k = 3): number {
  return Math.min(n, k) + Math.max(0, Math.log(1 + Math.max(0, n - k)) * 0.5);
}

/**
 * Matches input text against semantic clusters from semantic_thesaurus.json
 * Returns the strongest cluster match and any routing biases
 */
export function matchSemanticBackbone(
  text: string, 
  attachmentStyle: string,
  semanticThesaurus?: SemanticThesaurus
): SemanticBackboneResult {
  // Use dataLoader if no semanticThesaurus provided
  const thesaurus = semanticThesaurus || dataLoader.getSemanticThesaurus();
  
  if (!thesaurus || !text?.trim()) {
    return {
      primaryCluster: null,
      allMatches: [],
      routingBias: null,
      contextShift: {},
      attachmentOverride: null
    };
  }

  const normalizedText = text.toLowerCase();
  const clusters = thesaurus.clusters || {};
  const routingMatrix = thesaurus.routing_matrix || {};
  const attachmentOverrides = thesaurus.attachment_overrides || {};
  
  const matches: SemanticMatch[] = [];

  // Match against each semantic cluster
  Object.entries(clusters).forEach(([clusterName, clusterData]) => {
    const typedClusterData = clusterData as SemanticClusterData;
    const patterns = typedClusterData.patterns || [];
    const keywords = typedClusterData.keywords || [];
    const phrases = typedClusterData.phrases || [];
    
    let strength = 0;
    const matchedTerms: string[] = [];

    // Check pattern matches (regex patterns) - apply saturation
    let patternMatchCount = 0;
    patterns.forEach((pattern: string) => {
      try {
        const regex = new RegExp(pattern, 'gi');
        const patternMatches = normalizedText.match(regex);
        if (patternMatches) {
          patternMatchCount += patternMatches.length;
          matchedTerms.push(...patternMatches);
        }
      } catch (e) {
        // Skip invalid regex patterns
      }
    });
    const patternEff = sat(patternMatchCount, 3);
    strength += patternEff * 0.8; // High weight for pattern matches

    // Check keyword matches - apply saturation and word boundaries
    let keywordMatchCount = 0;
    keywords.forEach((keyword: string) => {
      const escapedKeyword = keyword.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const keywordRegex = new RegExp(`\\b${escapedKeyword.toLowerCase()}\\b`, 'gi');
      const keywordMatches = normalizedText.match(keywordRegex);
      if (keywordMatches) {
        keywordMatchCount += keywordMatches.length;
        matchedTerms.push(...keywordMatches);
      }
    });
    const keywordEff = sat(keywordMatchCount, 3);
    strength += keywordEff * 0.6; // Medium weight for keywords

    // Check phrase matches - apply saturation
    let phraseMatchCount = 0;
    phrases.forEach((phrase: string) => {
      if (normalizedText.includes(phrase.toLowerCase())) {
        phraseMatchCount += 1;
        matchedTerms.push(phrase);
      }
    });
    const phraseEff = sat(phraseMatchCount, 2);
    strength += phraseEff * 1.0; // High weight for exact phrase matches

    // Apply confidence calibration if available
    const confidenceMultiplier = typedClusterData.confidence_calibration || 1.0;
    strength *= confidenceMultiplier;

    if (strength > 0) {
      matches.push({
        cluster: clusterName,
        strength,
        matchedTerms: Array.from(new Set(matchedTerms)) // Remove duplicates
      });
    }
  });

  // Sort matches by strength
  matches.sort((a, b) => b.strength - a.strength);

  const primaryCluster = matches.length > 0 ? matches[0].cluster : null;
  
  // Get routing bias for primary cluster
  let routingBias: string | null = null;
  if (primaryCluster && routingMatrix[primaryCluster]) {
    const routes = routingMatrix[primaryCluster];
    // Find the route with highest weight
    const topRoute = Object.entries(routes)
      .sort(([,a], [,b]) => (b as number) - (a as number))[0];
    if (topRoute && (topRoute[1] as number) > 0.5) {
      routingBias = topRoute[0];
    }
  }

  // Apply attachment-specific overrides
  let attachmentOverride: string | null = null;
  if (primaryCluster && attachmentOverrides[attachmentStyle]) {
    const overrides = attachmentOverrides[attachmentStyle];
    if (overrides[primaryCluster]) {
      attachmentOverride = overrides[primaryCluster];
    }
  }

  // Calculate context shifts based on semantic matches
  const contextShift: Record<string, number> = {};
  matches.forEach(match => {
    const clusterData = clusters[match.cluster] as SemanticClusterData;
    const contextBias = clusterData.context_bias || {};
    Object.entries(contextBias).forEach(([context, weight]) => {
      const currentShift = contextShift[context] || 0;
      const newShift = currentShift + (weight * match.strength * 0.1);
      contextShift[context] = clamp01(newShift);
    });
  });

  return {
    primaryCluster,
    allMatches: matches,
    routingBias,
    contextShift,
    attachmentOverride
  };
}

/**
 * Apply semantic backbone results to tone analysis
 * Adjusts tone distribution based on semantic cluster matches
 */
export function applySemanticBias(
  toneDistribution: Record<string, number>,
  semanticResult: SemanticBackboneResult,
  semanticThesaurus: SemanticThesaurus
): Record<string, number> {
  if (!semanticResult.primaryCluster || !semanticThesaurus?.clusters) {
    return toneDistribution;
  }

  const clusterData = semanticThesaurus.clusters[semanticResult.primaryCluster];
  const toneBias = clusterData?.tone_bias || {};
  
  // Apply tone bias from semantic cluster
  const adjustedDistribution = { ...toneDistribution };
  Object.entries(toneBias).forEach(([tone, bias]) => {
    if (typeof bias === 'number' && adjustedDistribution[tone] !== undefined) {
      const currentValue = adjustedDistribution[tone];
      const biasedValue = currentValue + (bias * semanticResult.allMatches[0]?.strength * 0.1);
      adjustedDistribution[tone] = clamp01(biasedValue);
    }
  });

  // Normalize distribution
  const total = Object.values(adjustedDistribution).reduce((sum, val) => sum + val, 0);
  if (total > 0) {
    Object.keys(adjustedDistribution).forEach(key => {
      adjustedDistribution[key] /= total;
    });
  }

  return adjustedDistribution;
}