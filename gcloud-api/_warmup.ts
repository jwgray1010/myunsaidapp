import type { Request, Response } from 'express';
import { nliLocal } from './_lib/services/nliLocal';
import { dataLoader } from './_lib/services/dataLoader';

// Warmup endpoint for cold start optimization
// Preloads ML models and data files to reduce subsequent response times
export default async function handler(req: Request, res: Response) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const warmupStart = Date.now();
    const results: any = {
      timestamp: new Date().toISOString(),
      status: 'success',
      warmup_ms: 0,
      components: {}
    };

    // Warmup data loader
    const dataStart = Date.now();
    dataLoader.initializeSync();
    
    // Count successful loads by checking non-null values
    let filesLoaded = 0;
    const dataKeys = [
      'attachmentLearning', 'therapyAdvice', 'contextClassifier',
      'toneTriggerWords', 'intensityModifiers', 'evaluationTones',
      'tonePatterns', 'learningSignals', 'negationPatterns'
    ];
    
    for (const key of dataKeys) {
      try {
        const value = dataLoader.get(key);
        if (value !== null && value !== undefined) {
          filesLoaded++;
        }
      } catch {
        // File failed to load
      }
    }
    
    results.components.dataLoader = {
      status: 'loaded',
      time_ms: Date.now() - dataStart,
      files_loaded: filesLoaded,
      is_initialized: dataLoader.isInitialized()
    };

    // Warmup NLI model with batched test
    const nliStart = Date.now();
    await nliLocal.init();
    
    // Test batch scoring to warm up the pipeline
    const testPremise = 'The user needs help with relationships';
    const testHypotheses = [
      'This advice is relevant for the situation',
      'This suggestion helps with communication',
      'This guidance addresses the user concern'
    ];
    
    await nliLocal.scoreBatch([testPremise], testHypotheses);
    
    results.components.nliLocal = {
      status: 'initialized',
      time_ms: Date.now() - nliStart,
      model: 'transformers.js zero-shot classifier'
    };

    results.warmup_ms = Date.now() - warmupStart;

    return res.status(200).json(results);

  } catch (error) {
    console.error('Warmup failed:', error);
    return res.status(500).json({
      timestamp: new Date().toISOString(),
      status: 'error',
      error: error instanceof Error ? error.message : 'Unknown error'
    });
  }
}