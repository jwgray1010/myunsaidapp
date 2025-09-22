/**
 * Local ONNX-based Natural Language Inference (NLI) verifier
 * 
 * Provides entailment checking between user messages and therapy advice
 * to prevent semantic mismatches without cloud dependencies.
 * 
 * Compatible with Vercel Serverless - uses ONNX runtime for local inference.
 */

import { logger } from '../logger';
import { createHash } from 'crypto';

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
  runtime: 'node' | 'wasm' | 'rules-only';
  modelVersion: string;
  processingTimeMs: number;
  inputLength: number;
  confidence: number;
  fallbackUsed: boolean;
  errorCount: number;
}

/**
 * Local NLI verifier using ONNX runtime
 * Enhanced with dual runtime support, version tracking, and rules backstop
 * Supports both Node.js (onnxruntime-node) and Edge/WASM (onnxruntime-web)
 */
class NLILocalVerifier {
  private session: any = null;
  public ready: boolean = false;
  private modelPath: string | null = null;
  private isNode: boolean = false;
  private modelVersion: string = 'v1.0'; // Version tracking for cache invalidation
  private initAttempts: number = 0;
  private maxRetries: number = 3;
  private telemetryBuffer: NLITelemetry[] = [];
  private errorCount: number = 0;
  private dataVersionHash: string = '';

  constructor() {
    // Calculate data version hash for cache invalidation
    this.updateDataVersionHash();
  }

  /**
   * Calculate hash of critical data for cache invalidation
   */
  private updateDataVersionHash(): void {
    const criticalData = {
      modelVersion: this.modelVersion,
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
      runtime: this.isNode ? 'node' : (this.ready ? 'wasm' : 'rules-only'),
      modelVersion: this.modelVersion,
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
      runtime: this.isNode ? 'node' : (this.ready ? 'wasm' : 'rules-only'),
      avgProcessingTimeMs: Math.round(avgProcessingTime),
      fallbackRate: Math.round(fallbackRate * 100),
      errorCount: this.errorCount,
      totalOperations: this.telemetryBuffer.length
    };
  }

  /**
   * Initialize ONNX session with MNLI model
   * Feature-detects Node vs Edge/serverless and uses appropriate runtime
   */
  async init(modelPath?: string): Promise<void> {
    if (NLI_DISABLED) {
      logger.info('NLI explicitly disabled via DISABLE_NLI=1');
      this.ready = false;
      return;
    }

    try {
      this.modelPath = modelPath || process.env.NLI_ONNX_PATH || '/var/task/models/mnli-mini.onnx';
      
      // ✅ HARDENED: Dual runtime support with feature detection
      let ort: any;
      try {
        // Try Node.js runtime first (for serverful environments)
        ort = await eval(`import('onnxruntime-node')`);
        this.isNode = true;
        logger.info('Using onnxruntime-node (serverful mode)');
      } catch (nodeError) {
        try {
          // Fallback to WASM runtime (for serverless/edge)
          ort = await eval(`import('onnxruntime-web')`);
          this.isNode = false;
          logger.info('Using onnxruntime-web (serverless/WASM mode)');
        } catch (webError) {
          logger.warn('No ONNX runtime available', { 
            nodeError: nodeError instanceof Error ? nodeError.message : String(nodeError),
            webError: webError instanceof Error ? webError.message : String(webError)
          });
          this.ready = false;
          return;
        }
      }
      
      // Create session with appropriate options
      const sessionOptions = this.isNode 
        ? {} // Node.js can use default providers
        : { executionProviders: ['wasm'] }; // Force WASM for serverless
        
      this.session = await ort.InferenceSession.create(this.modelPath, sessionOptions);
      this.ready = true;
      
      logger.info('NLI verifier initialized successfully', { 
        modelPath: this.modelPath,
        runtime: this.isNode ? 'node' : 'wasm',
        disabled: NLI_DISABLED 
      });
      
    } catch (error) {
      logger.warn('Failed to initialize NLI verifier, falling back to rules-only', { 
        error: error instanceof Error ? error.message : String(error),
        modelPath: this.modelPath,
        isNode: this.isNode
      });
      this.ready = false;
    }
  }

  /**
   * Encode premise-hypothesis pair for MNLI model
   * Proper BERT-style encoding: [CLS] premise [SEP] hypothesis [SEP]
   * TODO: Replace with real WordPiece tokenizer (vocab.json/merges.txt)
   */
  private encodePair(premise: string, hypothesis: string): {
    input_ids: BigInt64Array;
    attention_mask: BigInt64Array;
    token_type_ids: BigInt64Array;
  } {
    // Enhanced stub tokenizer with proper segment encoding
    // In production: use real WordPiece/BPE tokenizer
    const maxLength = 128;
    const vocab = new Map<string, number>([
      ['[CLS]', 101], ['[SEP]', 102], ['[PAD]', 0], ['[UNK]', 100]
    ]);
    
    // Tokenize premise and hypothesis separately
    const premiseTokens = premise.toLowerCase().split(/\s+/).filter(t => t.length > 0);
    const hypothesisTokens = hypothesis.toLowerCase().split(/\s+/).filter(t => t.length > 0);
    
    // Add tokens to vocab dynamically (stub behavior)
    [...premiseTokens, ...hypothesisTokens].forEach((token, i) => {
      if (!vocab.has(token)) {
        vocab.set(token, i + 1000);
      }
    });
    
    // Build sequence: [CLS] premise [SEP] hypothesis [SEP]
    const sequence = [
      101, // [CLS]
      ...premiseTokens.map(token => vocab.get(token) || 100), // premise
      102, // [SEP]
      ...hypothesisTokens.map(token => vocab.get(token) || 100), // hypothesis
      102  // [SEP]
    ];
    
    // Truncate if too long
    const truncated = sequence.slice(0, maxLength - 1);
    if (truncated.length < sequence.length) {
      truncated[truncated.length - 1] = 102; // Ensure final [SEP]
    }
    
    // Pad to fixed length
    const input_ids = [...truncated];
    while (input_ids.length < maxLength) {
      input_ids.push(0); // [PAD]
    }
    
    // Create attention mask (1 for real tokens, 0 for padding)
    const attention_mask = input_ids.map(id => id === 0 ? 0 : 1);
    
    // Create token type IDs (0 for premise segment, 1 for hypothesis segment)
    const token_type_ids = new Array(maxLength).fill(0);
    let inHypothesis = false;
    let sepCount = 0;
    
    for (let i = 0; i < input_ids.length; i++) {
      if (input_ids[i] === 102) { // [SEP]
        sepCount++;
        if (sepCount === 1) {
          inHypothesis = true;
        }
      } else if (inHypothesis && input_ids[i] !== 0) {
        token_type_ids[i] = 1;
      }
    }
    
    return {
      input_ids: new BigInt64Array(input_ids.map(BigInt)),
      attention_mask: new BigInt64Array(attention_mask.map(BigInt)),
      token_type_ids: new BigInt64Array(token_type_ids.map(BigInt))
    };
  }

  /**
   * Score entailment between premise and hypothesis
   */
  async score(premise: string, hypothesis: string): Promise<NLIResult> {
    const startTime = Date.now();
    const inputLength = premise.length + hypothesis.length;
    
    if (!this.ready || !this.session) {
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
      // Use proper MNLI encoding with premise-hypothesis pairs
      const encoded = this.encodePair(premise, hypothesis);
      
      // Run inference
      const feeds = {
        input_ids: encoded.input_ids,
        attention_mask: encoded.attention_mask,
        token_type_ids: encoded.token_type_ids
      };
      
      const results = await this.session.run(feeds);
      const logits = results.logits.data;
      
      // Apply softmax to get probabilities
      // MNLI outputs: [contradiction, neutral, entailment]
      const exp = logits.map((x: number) => Math.exp(x));
      const sum = exp.reduce((a: number, b: number) => a + b, 0);
      const probs = exp.map((x: number) => x / sum);
      
      const result = {
        contra: probs[0] || 0,
        neutral: probs[1] || 0,
        entail: probs[2] || 0
      };
      
      // Track successful inference
      this.addTelemetry({
        processingTimeMs: Date.now() - startTime,
        inputLength,
        confidence: Math.max(...probs),
        fallbackUsed: false
      });
      
      return result;
    } catch (error) {
      this.errorCount++;
      
      this.addTelemetry({
        processingTimeMs: Date.now() - startTime,
        inputLength,
        confidence: 0.33,
        fallbackUsed: true
      });
      
      logger.warn('NLI scoring failed', { 
        error: error instanceof Error ? error.message : String(error),
        dataVersion: this.dataVersionHash,
        errorCount: this.errorCount
      });
      
      return { entail: 0.33, contra: 0.33, neutral: 0.34 };
    }
  }

  /**
   * Rules-only backstop for when NLI model is unavailable
   * Maintains fit gate functionality through heuristic matching
   */
  rulesBackstop(text: string, advice: { text: string; intents?: string[]; context?: string; category?: string }): boolean {
    const userIntents = detectUserIntents(text);
    const adviceIntents = advice.intents || [];
    const adviceContext = advice.context;
    const adviceCategory = advice.category;
    
    console.log(`[nli-rules] User intents: [${userIntents.join(', ')}]`);
    console.log(`[nli-rules] Advice intents: [${adviceIntents.join(', ')}], context: ${adviceContext}, category: ${adviceCategory}`);
    
    // Rule 1: Intent overlap (highest confidence)
    const intentOverlap = userIntents.filter(intent => adviceIntents.includes(intent));
    if (intentOverlap.length > 0) {
      console.log(`[nli-rules] ✓ Intent overlap: [${intentOverlap.join(', ')}]`);
      return true;
    }
    
    // Rule 2: Context match (medium confidence)
    if (adviceContext) {
      const detectedContext = this.detectContext(text);
      if (detectedContext === adviceContext) {
        console.log(`[nli-rules] ✓ Context match: ${detectedContext}`);
        return true;
      }
    }
    
    // Rule 3: Category overlap with user sentiment (lower confidence)
    if (adviceCategory) {
      const textSentiment = this.detectSentiment(text);
      const categoryMatches = this.checkCategoryAlignment(textSentiment, adviceCategory);
      if (categoryMatches) {
        console.log(`[nli-rules] ✓ Category alignment: ${textSentiment} → ${adviceCategory}`);
        return true;
      }
    }
    
    // Rule 4: Emergency fallback - basic keyword overlap
    const textWords = new Set(text.toLowerCase().split(/\s+/).filter(w => w.length > 3));
    const adviceWords = new Set(advice.text.toLowerCase().split(/\s+/).filter(w => w.length > 3));
    const wordOverlap = [...textWords].filter(word => adviceWords.has(word));
    
    if (wordOverlap.length >= 2) {
      console.log(`[nli-rules] ✓ Keyword overlap: [${wordOverlap.join(', ')}]`);
      return true;
    }
    
    console.log(`[nli-rules] ✗ No rules match - advice rejected`);
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