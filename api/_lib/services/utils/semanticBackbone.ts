// api/_lib/services/utils/semanticBackbone.ts
// Semantic backbone matching and analysis using semantic_thesaurus.json

export interface SemanticMatch {
  cluster: string;
  strength: number;
  matchedTerms: string[];
}

export interface SemanticBackboneResult {
  primaryCluster: string | null;
  allMatches: SemanticMatch[];
  routingBias: string | null;
  contextShift: Record<string, number>;
  attachmentOverride: string | null;
}

/**
 * Matches input text against semantic clusters from semantic_thesaurus.json
 * Returns the strongest cluster match and any routing biases
 */
export function matchSemanticBackbone(
  text: string, 
  attachmentStyle: string,
  semanticThesaurus: any
): SemanticBackboneResult {
  if (!semanticThesaurus || !text?.trim()) {
    return {
      primaryCluster: null,
      allMatches: [],
      routingBias: null,
      contextShift: {},
      attachmentOverride: null
    };
  }

  const normalizedText = text.toLowerCase();
  const clusters = semanticThesaurus.clusters || {};
  const routingMatrix = semanticThesaurus.routing_matrix || {};
  const attachmentOverrides = semanticThesaurus.attachment_overrides || {};
  
  const matches: SemanticMatch[] = [];

  // Match against each semantic cluster
  Object.entries(clusters).forEach(([clusterName, clusterData]: [string, any]) => {
    const patterns = clusterData.patterns || [];
    const keywords = clusterData.keywords || [];
    const phrases = clusterData.phrases || [];
    
    let strength = 0;
    const matchedTerms: string[] = [];

    // Check pattern matches (regex patterns)
    patterns.forEach((pattern: string) => {
      try {
        const regex = new RegExp(pattern, 'gi');
        const patternMatches = normalizedText.match(regex);
        if (patternMatches) {
          strength += patternMatches.length * 0.8; // High weight for pattern matches
          matchedTerms.push(...patternMatches);
        }
      } catch (e) {
        // Skip invalid regex patterns
      }
    });

    // Check keyword matches
    keywords.forEach((keyword: string) => {
      const keywordRegex = new RegExp(`\\b${keyword.toLowerCase()}\\b`, 'gi');
      const keywordMatches = normalizedText.match(keywordRegex);
      if (keywordMatches) {
        strength += keywordMatches.length * 0.6; // Medium weight for keywords
        matchedTerms.push(...keywordMatches);
      }
    });

    // Check phrase matches
    phrases.forEach((phrase: string) => {
      if (normalizedText.includes(phrase.toLowerCase())) {
        strength += 1.0; // High weight for exact phrase matches
        matchedTerms.push(phrase);
      }
    });

    // Apply confidence calibration if available
    const confidenceMultiplier = clusterData.confidence_calibration || 1.0;
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
    const clusterData = clusters[match.cluster];
    const contextBias = clusterData.context_bias || {};
    Object.entries(contextBias).forEach(([context, weight]: [string, any]) => {
      contextShift[context] = (contextShift[context] || 0) + (weight * match.strength * 0.1);
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
  semanticThesaurus: any
): Record<string, number> {
  if (!semanticResult.primaryCluster || !semanticThesaurus?.clusters) {
    return toneDistribution;
  }

  const clusterData = semanticThesaurus.clusters[semanticResult.primaryCluster];
  const toneBias = clusterData?.tone_bias || {};
  
  // Apply tone bias from semantic cluster
  const adjustedDistribution = { ...toneDistribution };
  Object.entries(toneBias).forEach(([tone, bias]: [string, any]) => {
    if (typeof bias === 'number' && adjustedDistribution[tone] !== undefined) {
      adjustedDistribution[tone] = Math.max(0, Math.min(1, 
        adjustedDistribution[tone] + (bias * semanticResult.allMatches[0]?.strength * 0.1)
      ));
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