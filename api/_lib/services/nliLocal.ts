/**
 * Local ONNX-based Natural Language Inference (NLI) verifier
 * 
 * Provides entailment checking between user messages and therapy advice
 * to prevent semantic mismatches without cloud dependencies.
 * 
 * Compatible with Vercel Serverless - uses ONNX runtime for local inference.
 */

import { logger } from '../logger';

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

/**
 * Local NLI verifier using ONNX runtime
 * Serverless-safe, no external API calls
 */
class NLILocalVerifier {
  private session: any = null;
  public ready: boolean = false;
  private modelPath: string | null = null;

  /**
   * Initialize ONNX session with MNLI model
   */
  async init(modelPath?: string): Promise<void> {
    if (NLI_DISABLED) {
      logger.info('NLI explicitly disabled via DISABLE_NLI=1');
      this.ready = false;
      return;
    }

    try {
      this.modelPath = modelPath || process.env.NLI_ONNX_PATH || '/var/task/models/mnli-mini.onnx';
      
      // Dynamic import for serverless compatibility
      // Will fail gracefully if onnxruntime-node not installed
      try {
        const ort = await eval(`import('onnxruntime-node')`);
        // Load the MNLI model
        this.session = await ort.InferenceSession.create(this.modelPath);
        this.ready = true;
        
        logger.info('NLI verifier initialized successfully', { 
          modelPath: this.modelPath,
          disabled: NLI_DISABLED 
        });
      } catch (importError) {
        logger.warn('onnxruntime-node not available, NLI disabled', { 
          error: importError instanceof Error ? importError.message : String(importError) 
        });
        this.ready = false;
      }
    } catch (error) {
      logger.warn('Failed to initialize NLI verifier, falling back to rules-only', { 
        error: error instanceof Error ? error.message : String(error),
        modelPath: this.modelPath 
      });
      this.ready = false;
    }
  }

  /**
   * Tokenize text for MNLI model
   * Stub implementation - will be replaced with real tokenizer JSON
   */
  private tokenize(text: string): { input_ids: number[]; attention_mask: number[] } {
    // Simple stub tokenizer - replace with actual tokenizer
    const tokens = text.toLowerCase().split(/\s+/).slice(0, 128);
    const vocab = new Map<string, number>([
      ['[CLS]', 101], ['[SEP]', 102], ['[PAD]', 0], ['[UNK]', 100]
    ]);
    
    // Add basic vocabulary
    tokens.forEach((token, i) => {
      if (!vocab.has(token)) {
        vocab.set(token, i + 1000);
      }
    });
    
    const input_ids = [
      101, // [CLS]
      ...tokens.map(token => vocab.get(token) || 100), // [UNK] for unknown
      102  // [SEP]
    ];
    
    // Pad to fixed length
    const maxLength = 128;
    while (input_ids.length < maxLength) {
      input_ids.push(0); // [PAD]
    }
    
    const attention_mask = input_ids.map(id => id === 0 ? 0 : 1);
    
    return { 
      input_ids: input_ids.slice(0, maxLength), 
      attention_mask: attention_mask.slice(0, maxLength) 
    };
  }

  /**
   * Score entailment between premise and hypothesis
   */
  async score(premise: string, hypothesis: string): Promise<NLIResult> {
    if (!this.ready || !this.session) {
      // Return neutral scores when NLI unavailable
      return { entail: 0.33, contra: 0.33, neutral: 0.34 };
    }

    try {
      // Combine premise and hypothesis for MNLI format
      const combined = `${premise} [SEP] ${hypothesis}`;
      const tokens = this.tokenize(combined);
      
      // Create input tensors
      const inputIds = new Float32Array(tokens.input_ids);
      const attentionMask = new Float32Array(tokens.attention_mask);
      
      // Run inference
      const feeds = {
        input_ids: inputIds,
        attention_mask: attentionMask
      };
      
      const results = await this.session.run(feeds);
      const logits = results.logits.data;
      
      // Apply softmax to get probabilities
      // MNLI outputs: [contradiction, neutral, entailment]
      const exp = logits.map((x: number) => Math.exp(x));
      const sum = exp.reduce((a: number, b: number) => a + b, 0);
      const probs = exp.map((x: number) => x / sum);
      
      return {
        contra: probs[0] || 0,
        neutral: probs[1] || 0,
        entail: probs[2] || 0
      };
    } catch (error) {
      logger.warn('NLI scoring failed', { error: error instanceof Error ? error.message : String(error) });
      return { entail: 0.33, contra: 0.33, neutral: 0.34 };
    }
  }
}

/**
 * Generate hypothesis from therapy advice for NLI checking
 */
export function hypothesisForAdvice(advice: any): string {
  if (!advice || !advice.advice) {
    return 'This advice is appropriate for the message.';
  }

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
  
  // Default hypothesis
  return `This therapy advice is appropriate for the message context.`;
}

// Singleton instance
export const nliLocal = new NLILocalVerifier();

// Export types
export type { NLIResult, FitResult };