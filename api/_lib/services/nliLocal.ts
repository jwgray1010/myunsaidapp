/**
 * Local NLI verifier using @xenova/transformers
 * 
 * Provides entailment checking between user messages and therapy advice
 * to prevent semantic mismatches without cloud dependencies.
 * 
 * Compatible with Vercel Serverless - uses transformers.js for automatic model handling.
 */

import { logger } from '../logger.js';
import { pipeline } from '@xenova/transformers';

// Safe crypto import for serverless environments with deterministic fallback
let createHash: any;
function djb2(s: string): string { 
  let h = 5381; 
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h) + s.charCodeAt(i); 
  return (h >>> 0).toString(16); 
}

try {
  createHash = require('crypto').createHash;
} catch (error) {
  console.warn('[nli] Crypto module not available, using deterministic fallback');
  createHash = (_: string) => {
    const buf: string[] = [];
    return {
      update(data: any) { buf.push(String(data)); return this; },
      digest() { return djb2(buf.join('')); }
    };
  };
}

// Environment flag to disable NLI
const NLI_DISABLED = process.env.DISABLE_NLI === '1';

interface NLIResult {
  entail: number;
  contra: number;
  neutral: number;
}

interface FitResult {
  ok: boolean;
  entail: number;
  contra: number;
  reason: string;
}

interface NLITelemetry {
  timestamp: number;
  runtime: 'wasm' | 'rules-only';
  modelVersion: string;
  processingTimeMs: number;
  inputLength: number;
  confidence: number;
  fallbackUsed: boolean;
  errorCount: number;
}

/**
 * Local NLI verifier using @xenova/transformers
 * Enhanced with transformers.js pipeline for automatic model handling
 * Supports serverless deployment with automatic model downloading
 */
class NLILocalVerifier {
  private classifier: any = null;
  public ready: boolean = false;
  private modelName: string = 'facebook/bart-large-mnli'; // Small, fast NLI model
  private initAttempts: number = 0;
  private maxRetries: number = 3;
  private telemetryBuffer: NLITelemetry[] = [];
  private errorCount: number = 0;
  private dataVersionHash: string = '';
  private labelMapping = { 'CONTRADICTION': 'contra', 'NEUTRAL': 'neutral', 'ENTAILMENT': 'entail' };

  constructor() {
    // Calculate data version hash for cache invalidation
    this.updateDataVersionHash();
  }

  /**
   * Calculate hash of critical data for cache invalidation
   */
  private updateDataVersionHash(): void {
    const criticalData = {
      modelName: this.modelName,
      nodeVersion: process.version,
      timestamp: Date.now(),
      environment: process.env.NODE_ENV || 'development'
    };
    
    this.dataVersionHash = createHash('sha256')
      .update(JSON.stringify(criticalData))
      .digest('hex')
      .slice(0, 8); // Short hash for logging
      
    console.log(`[nli] Data version hash: ${this.dataVersionHash}`);
  }

  /**
   * Add telemetry data point
   */
  private addTelemetry(data: Partial<NLITelemetry>): void {
    const telemetry: NLITelemetry = {
      timestamp: Date.now(),
      runtime: this.ready ? 'wasm' : 'rules-only',
      modelVersion: this.modelName,
      processingTimeMs: 0,
      inputLength: 0,
      confidence: 0,
      fallbackUsed: !this.ready,
      errorCount: this.errorCount,
      ...data
    };
    
    this.telemetryBuffer.push(telemetry);
    
    // Keep buffer manageable
    if (this.telemetryBuffer.length > 100) {
      this.telemetryBuffer = this.telemetryBuffer.slice(-50);
    }
    
    // Log significant events
    if (data.fallbackUsed || (data.confidence && data.confidence < 0.3)) {
      logger.info('NLI telemetry', { 
        hash: this.dataVersionHash,
        runtime: telemetry.runtime,
        confidence: telemetry.confidence,
        fallback: telemetry.fallbackUsed
      });
    }
  }

  /**
   * Get telemetry summary for debugging
   */
  getTelemetrySummary(): any {
    if (this.telemetryBuffer.length === 0) return null;
    
    const recent = this.telemetryBuffer.slice(-10);
    const avgProcessingTime = recent.reduce((sum, t) => sum + t.processingTimeMs, 0) / recent.length;
    const fallbackRate = recent.filter(t => t.fallbackUsed).length / recent.length;
    
    return {
      dataVersion: this.dataVersionHash,
      runtime: this.ready ? 'wasm' : 'rules-only',
      avgProcessingTimeMs: Math.round(avgProcessingTime),
      fallbackRate: Math.round(fallbackRate * 100),
      errorCount: this.errorCount,
      totalOperations: this.telemetryBuffer.length
    };
  }

  /**
   * Initialize transformers.js pipeline for NLI
   */
  async init(): Promise<void> {
    if (NLI_DISABLED) {
      logger.info('NLI explicitly disabled via DISABLE_NLI=1');
      this.ready = false;
      return;
    }

    try {
      // Initialize zero-shot classification pipeline
      // Using a smaller, faster model suitable for serverless
      this.classifier = await pipeline('zero-shot-classification', 'microsoft/DialoGPT-medium');
      
      this.ready = true;
      
      logger.info('NLI verifier initialized successfully with transformers.js', { 
        modelName: this.modelName,
        runtime: 'transformers.js'
      });
      
    } catch (error) {
      logger.warn('Failed to initialize NLI verifier, falling back to rules-only', { 
        error: error instanceof Error ? error.message : String(error)
      });
      this.ready = false;
    }
  }

  /**
   * Score entailment between premise and hypothesis using transformers.js
   */
  async score(premise: string, hypothesis: string): Promise<NLIResult> {
    const startTime = Date.now();
    const inputLength = premise.length + hypothesis.length;
    
    if (!this.ready || !this.classifier) {
      this.addTelemetry({
        processingTimeMs: Date.now() - startTime,
        inputLength,
        confidence: 0.33,
        fallbackUsed: true
      });
      
      // Return neutral scores when NLI unavailable
      return { entail: 0.33, contra: 0.33, neutral: 0.34 };
    }

    try {
      // Use zero-shot classification with entailment labels
      const candidateLabels = ['contradiction', 'neutral', 'entailment'];
      const sequence = `${premise} [SEP] ${hypothesis}`;
      
      // Timeout protection
      const timeoutMs = Number(process.env.NLI_TIMEOUT_MS || 400);
      const result = await Promise.race([
        this.classifier(sequence, candidateLabels),
        new Promise<any>((_, reject) => 
          setTimeout(() => reject(new Error('NLI timeout')), timeoutMs)
        )
      ]);
      
      // Map results to our format
      const scores = { entail: 0.33, contra: 0.33, neutral: 0.34 };
      
      if (result?.scores && result?.labels) {
        for (let i = 0; i < result.labels.length; i++) {
          const label = result.labels[i].toLowerCase();
          const score = result.scores[i];
          
          if (label.includes('entail')) scores.entail = score;
          else if (label.includes('contra')) scores.contra = score;
          else if (label.includes('neutral')) scores.neutral = score;
        }
      }
      
      const maxScore = Math.max(scores.entail, scores.contra, scores.neutral);
      
      this.addTelemetry({
        processingTimeMs: Date.now() - startTime,
        inputLength,
        confidence: maxScore,
        fallbackUsed: false
      });
      
      return scores;
      
    } catch (error) {
      this.errorCount++;
      
      this.addTelemetry({
        processingTimeMs: Date.now() - startTime,
        inputLength,
        confidence: 0.33,
        fallbackUsed: true
      });
      
      const isTimeout = error instanceof Error && error.message === 'NLI timeout';
      logger.warn(isTimeout ? 'NLI timeout' : 'NLI scoring failed', { 
        error: error instanceof Error ? error.message : String(error),
        errorCount: this.errorCount,
        isTimeout
      });
      
      return { entail: 0.33, contra: 0.33, neutral: 0.34 };
    }
  }

  /**
   * Enhanced rules-only backstop with spaCy context integration
   * Maintains fit gate functionality through heuristic matching
   */
  rulesBackstop(
    text: string, 
    advice: { text: string; intents?: string[]; context?: string; category?: string },
    spacyContext?: { label?: string; score?: number },
    negScopes?: Array<{ start: number; end: number }>
  ): boolean {
    const userIntents = detectUserIntents(text);
    const adviceIntents = advice.intents || [];
    const adviceContext = advice.context;
    const adviceCategory = advice.category;
    
    logger.info(`[nli-rules] User intents: [${userIntents.join(', ')}]`);
    logger.info(`[nli-rules] Advice intents: [${adviceIntents.join(', ')}], context: ${adviceContext}, category: ${adviceCategory}`);
    
    // Enhanced Rule 1: Intent overlap with negation consideration
    const intentOverlap = userIntents.filter(intent => adviceIntents.includes(intent));
    if (intentOverlap.length > 0) {
      // Down-weight positive intents under heavy negation
      const hasHeavyNegation = negScopes && negScopes.length > 2;
      const positiveIntents = ['expressing_appreciation', 'expressing_affection', 'making_commitment', 'expressing_positivity'];
      const isPositiveAdvice = intentOverlap.some(intent => positiveIntents.includes(intent));
      
      if (hasHeavyNegation && isPositiveAdvice) {
        logger.info(`[nli-rules] ⚠ Positive intent under heavy negation - reduced confidence`);
        return false; // Don't match positive advice to heavily negated text
      }
      
      logger.info(`[nli-rules] ✓ Intent overlap: [${intentOverlap.join(', ')}]`);
      return true;
    }
    
    // Enhanced Rule 2: Context match with spaCy integration
    if (adviceContext) {
      const detectedContext = spacyContext?.label || this.detectContext(text);
      const contextScore = spacyContext?.score || 0.5;
      
      if (detectedContext === adviceContext && contextScore > 0.3) {
        logger.info(`[nli-rules] ✓ Context match: ${detectedContext} (score: ${contextScore.toFixed(2)})`);
        return true;
      }
    }
    
    // Rule 3: Category overlap with user sentiment (lower confidence)
    if (adviceCategory) {
      const textSentiment = this.detectSentiment(text);
      const categoryMatches = this.checkCategoryAlignment(textSentiment, adviceCategory);
      if (categoryMatches) {
        logger.info(`[nli-rules] ✓ Category alignment: ${textSentiment} → ${adviceCategory}`);
        return true;
      }
    }
    
    // Rule 4: Emergency fallback - basic keyword overlap
    const textWords = new Set(text.toLowerCase().split(/\s+/).filter(w => w.length > 3));
    const adviceWords = new Set(advice.text.toLowerCase().split(/\s+/).filter(w => w.length > 3));
    const wordOverlap = Array.from(textWords).filter(word => adviceWords.has(word));
    
    if (wordOverlap.length >= 2) {
      logger.info(`[nli-rules] ✓ Keyword overlap: [${wordOverlap.join(', ')}]`);
      return true;
    }
    
    logger.info(`[nli-rules] ✗ No rules match - advice rejected`);
    return false;
  }
  
  /**
   * Simple context detection for rules backstop
   */
  private detectContext(text: string): string {
    const normalizedText = text.toLowerCase();
    
    if (/\b(fight|argue|angry|mad|conflict|disagree)\b/.test(normalizedText)) return 'conflict';
    if (/\b(love|romance|intimate|date|kiss|relationship)\b/.test(normalizedText)) return 'romance';
    if (/\b(kid|child|parent|school|family|baby)\b/.test(normalizedText)) return 'family';
    if (/\b(work|job|colleague|boss|career|meeting)\b/.test(normalizedText)) return 'professional';
    if (/\b(friend|social|party|hang out|group)\b/.test(normalizedText)) return 'friendship';
    if (/\b(money|financial|budget|expensive|cost)\b/.test(normalizedText)) return 'financial';
    if (/\b(travel|vacation|trip|visit|journey)\b/.test(normalizedText)) return 'travel';
    if (/\b(health|sick|doctor|medical|pain)\b/.test(normalizedText)) return 'health';
    if (/\b(goal|plan|future|dream|achieve)\b/.test(normalizedText)) return 'planning';
    
    return 'general';
  }
  
  /**
   * Basic sentiment detection for category alignment
   */
  private detectSentiment(text: string): 'positive' | 'negative' | 'neutral' {
    const normalizedText = text.toLowerCase();
    
    const positiveWords = /\b(happy|love|excited|great|wonderful|amazing|good|nice|perfect|awesome)\b/g;
    const negativeWords = /\b(sad|angry|frustrated|upset|hurt|disappointed|terrible|awful|hate|bad)\b/g;
    
    const positiveCount = (normalizedText.match(positiveWords) || []).length;
    const negativeCount = (normalizedText.match(negativeWords) || []).length;
    
    if (positiveCount > negativeCount && positiveCount > 0) return 'positive';
    if (negativeCount > positiveCount && negativeCount > 0) return 'negative';
    return 'neutral';
  }
  
  /**
   * Check if advice category aligns with user sentiment
   */
  private checkCategoryAlignment(sentiment: string, category: string): boolean {
    const categoryMappings: Record<string, string[]> = {
      'positive': ['appreciation', 'affection', 'support', 'encouragement', 'celebration'],
      'negative': ['conflict_resolution', 'emotional_support', 'boundary_setting', 'repair', 'validation'],
      'neutral': ['communication', 'planning', 'information', 'guidance', 'general']
    };
    
    const alignedCategories = categoryMappings[sentiment] || [];
    return alignedCategories.some(aligned => category.includes(aligned));
  }
}

/**
 * Intent-to-hypothesis mapping for more precise NLI checking
 * Uses enriched therapy advice intents instead of text pattern matching
 */
const INTENT_HYPOTHESES: Record<string, string> = {
  // De-escalation & Conflict
  'deescalate': 'The conversation is heated and needs de-escalation.',
  'interrupt_spiral': 'The conversation is spiraling and needs interruption.',
  'clarify': 'The person is expressing confusion or needs clarification.',
  'pause_interaction': 'The interaction needs a pause or break.',
  
  // Repair & Connection
  'reconnect': 'The person wants to restore connection after conflict.',
  'offer_repair': 'The person should offer repair after causing harm.',
  'name_rupture': 'A relationship rupture has occurred and needs acknowledgment.',
  'accountability': 'The person should take accountability for their actions.',
  
  // Boundaries & Self-Protection
  'set_boundary': 'The person needs to set or discuss boundaries.',
  'protect_capacity': 'The person needs to protect their capacity or energy.',
  'protect_safety': 'The person needs to ensure their safety.',
  'balance_power': 'There is a power imbalance that needs addressing.',
  'set_process': 'The interaction needs a clearer process or structure.',
  
  // Emotional Support & Validation
  'request_validation': 'The person needs validation or acknowledgment.',
  'request_reassurance': 'The person needs reassurance or emotional support.',
  'request_closeness': 'The person is seeking emotional or physical closeness.',
  'request_presence': 'The person needs undivided attention or presence.',
  'express_gratitude': 'Gratitude or appreciation should be expressed.',
  
  // Vulnerability & Disclosure
  'disclose': 'The person wants to share something vulnerable or private.',
  'ask_consent': 'Permission should be asked before sharing sensitive information.',
  'co_regulate': 'The person needs co-regulation or mutual soothing.',
  
  // Practical & Planning
  'plan': 'Logistics or planning needs to be coordinated.',
  'confirm': 'Plans or arrangements need confirmation.',
  'align_logistics': 'Co-parenting or logistical coordination is needed.',
  'align_parenting': 'Parenting approaches need alignment.',
  
  // Support & Assessment
  'check_in': 'A mental health or emotional check-in is needed.',
  'ask_for_time': 'The person needs time to think or process.',
  'seek_ack': 'The person seeks acknowledgment for their contributions.',
  'rebalance_work': 'Invisible labor or work distribution needs rebalancing.',
  
  // Additional intents to reduce unknown intent logs
  'offer_support': 'The person should offer emotional or practical support.',
  'validate_feelings': 'The person\'s feelings need to be validated.',
  'share_perspective': 'A different perspective should be shared.',
  'suggest_solution': 'A practical solution should be suggested.',
  'request_space': 'The person needs physical or emotional space.',
  'show_appreciation': 'Appreciation or recognition should be shown.',
  'offer_comfort': 'Comfort or reassurance should be provided.',
  'seek_clarity': 'Clarification or understanding is needed.',
  'express_concern': 'Concern or worry should be expressed.',
  'propose_compromise': 'A compromise or middle ground should be found.',
};

/**
 * Generate hypothesis from therapy advice for NLI checking
 * Now uses enriched intents field for more precise hypothesis generation
 */
export function hypothesisForAdvice(advice: any): string {
  if (!advice || !advice.advice) {
    return 'This advice is appropriate for the message.';
  }

  // ✅ NEW: Use enriched intents field first (primary method)
  if (advice.intents && Array.isArray(advice.intents) && advice.intents.length > 0) {
    // Use the first (primary) intent for hypothesis generation
    const primaryIntent = advice.intents[0];
    const hypothesis = INTENT_HYPOTHESES[primaryIntent];
    
    if (hypothesis) {
      logger.info('NLI hypothesis from intent', { 
        adviceId: advice.id, 
        intent: primaryIntent, 
        hypothesis,
        allIntents: advice.intents 
      });
      return hypothesis;
    }
    
    // Log when we have intents but no mapping
    logger.warn('Unknown intent in therapy advice', { 
      adviceId: advice.id, 
      intent: primaryIntent, 
      allIntents: advice.intents 
    });
  }

  // ✅ FALLBACK: Use text pattern matching for advice without intents
  const adviceText = advice.advice.toLowerCase();
  
  // Generate contextual hypotheses based on advice content
  if (adviceText.includes('listen or help solve')) {
    return 'The person is unclear about what type of support they need.';
  }
  
  if (adviceText.includes('want to understand')) {
    return 'The person is expressing confusion or needs clarification.';
  }
  
  if (adviceText.includes('feeling heard')) {
    return 'The person feels unheard or needs emotional validation.';
  }
  
  if (adviceText.includes('take a break') || adviceText.includes('pause')) {
    return 'The conversation is heated and needs de-escalation.';
  }
  
  if (adviceText.includes('boundary') || adviceText.includes('limit')) {
    return 'The person needs to set or discuss boundaries.';
  }
  
  if (adviceText.includes('sorry') || adviceText.includes('apologize')) {
    return 'The person should offer an apology or repair.';
  }
  
  logger.info('NLI hypothesis from text pattern fallback', { 
    adviceId: advice.id, 
    hasIntents: !!advice.intents 
  });
  
  // Default hypothesis
  return `This therapy advice is appropriate for the message context.`;
}

/**
 * Enhanced user intent detection with dependency patterns and negation handling
 */
export function detectUserIntents(text: string): string[] {
  const intents = new Set<string>();
  const normalizedText = text.toLowerCase();
  
  // Check for negation patterns that might reverse intent
  const hasNegation = /\b(not|don't|doesn't|won't|can't|shouldn't|never|no)\b/.test(normalizedText);
  
  // Enhanced pattern matching with context awareness
  const intentPatterns: Array<{
    intent: string;
    patterns: RegExp[];
    contexts?: string[];
  }> = [
    // Emotional expression patterns
    { intent: 'seeking_validation', patterns: [/\bam i\b.*\b(right|wrong|crazy|overreacting)\b/, /\bdo you think i\b/, /\bvalidate\b.*\bfeelings?\b/] },
    { intent: 'expressing_frustration', patterns: [/\b(frustrated|annoyed|irritated|fed up)\b/, /\bcan't believe\b/, /\bdriving me\b.*\b(crazy|nuts)\b/] },
    { intent: 'requesting_clarity', patterns: [/\bwhat (do you mean|does that mean)\b/, /\bi don't understand\b/, /\bcan you explain\b/] },
    { intent: 'setting_boundaries', patterns: [/\bi need (space|time|boundaries)\b/, /\bstop (doing|saying)\b/, /\bthat's not okay\b/] },
    { intent: 'expressing_hurt', patterns: [/\bthat hurt\b/, /\bi feel hurt\b/, /\byou hurt my\b/, /\bwhy would you\b.*\bsay that\b/] },
    { intent: 'seeking_reassurance', patterns: [/\bdo you still\b.*\b(love|care|want)\b/, /\bare we okay\b/, /\bi worry that\b/] },
    { intent: 'requesting_change', patterns: [/\bi wish you would\b/, /\bcan you (please )?(try to |start |stop )\b/, /\bi need you to\b/] },
    { intent: 'expressing_appreciation', patterns: [/\bthank you\b/, /\bi appreciate\b/, /\bthat means a lot\b/, /\bi'm grateful\b/] },
    { intent: 'sharing_concern', patterns: [/\bi'm (worried|concerned) about\b/, /\bwhat if\b/, /\bi think we should\b.*\btalk\b/] },
    { intent: 'planning_together', patterns: [/\blet's (plan|do|go|try)\b/, /\bwhat about\b.*\b(we|us)\b/, /\bhow about we\b/] },
    { intent: 'expressing_affection', patterns: [/\bi love you\b/, /\bi miss you\b/, /\byou mean everything\b/] },
    { intent: 'asking_for_support', patterns: [/\bi need (help|support)\b/, /\bcan you be there\b/, /\bi'm struggling\b/] },
    { intent: 'making_commitment', patterns: [/\bi promise\b/, /\bi'll (try|do|be)\b/, /\bi commit to\b/] },
    { intent: 'expressing_regret', patterns: [/\bi'm sorry\b/, /\bi regret\b/, /\bi shouldn't have\b/, /\bmy bad\b/] },
    { intent: 'sharing_excitement', patterns: [/\bi'm so excited\b/, /\bguess what\b/, /\byou'll never believe\b/] },
    { intent: 'expressing_disappointment', patterns: [/\bi'm disappointed\b/, /\bi expected\b.*\bbut\b/, /\bi thought you would\b/] },
    
    // Context-weighted patterns (stronger in certain contexts)
    { intent: 'conflict_resolution', patterns: [/\blet's talk about\b/, /\bwe need to discuss\b/, /\bcan we work through\b/], contexts: ['conflict', 'argument'] },
    { intent: 'intimacy_building', patterns: [/\bi want to be closer\b/, /\bfeel connected\b/, /\bshare with you\b/], contexts: ['relationship', 'romance'] },
    { intent: 'parenting_coordination', patterns: [/\bthe kids?\b/, /\bour (son|daughter|children)\b/, /\bschool pickup\b/], contexts: ['family', 'parenting'] }
  ];
  
  // Apply patterns with negation handling
  for (const { intent, patterns, contexts } of intentPatterns) {
    const matchFound = patterns.some((pattern: RegExp) => pattern.test(normalizedText));
    
    if (matchFound) {
      // Apply context weighting if specified
      let confidence = 1.0;
      if (contexts) {
        // TODO: Context detection from previous tone analysis
        // For now, assume general context reduces confidence slightly
        confidence = 0.8;
      }
      
      // Handle negation (reverses some intents)
      if (hasNegation) {
        const negationReversible = ['expressing_appreciation', 'expressing_affection', 'making_commitment'];
        if (negationReversible.includes(intent)) {
          confidence *= 0.3; // Heavily reduce confidence for negated positive intents
        }
      }
      
      // Add intent if confidence threshold met
      if (confidence > 0.5) {
        intents.add(intent);
      }
    }
  }
  
  // Fallback to basic sentiment if no specific intents detected
  if (intents.size === 0) {
    if (/\b(love|happy|excited|great|wonderful|amazing)\b/.test(normalizedText)) {
      intents.add('expressing_positivity');
    } else if (/\b(sad|upset|angry|frustrated|disappointed|hurt)\b/.test(normalizedText)) {
      intents.add('expressing_difficulty');
    } else {
      intents.add('general_communication');
    }
  }
  
  return Array.from(intents);
}

// Singleton instance
export const nliLocal = new NLILocalVerifier();

// Export types
export type { NLIResult, FitResult };