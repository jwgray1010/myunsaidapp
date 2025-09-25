// api/_lib/services/dataLoader.ts
import * as fs from 'fs';
import * as path from 'path';
import { z } from 'zod';
import { logger } from '../logger';
import type {
  AttachmentLearningConfig,
  DataCache,
  TherapyAdviceFile,
  ContextClassifierFile,
  ToneTriggerWordsFile,
  IntensityModifiersFile,
  SarcasmIndicatorsFile,
  NegationIndicatorsFile,
  NegationPatternsFile,
  PhraseEdgesFile,
  EvaluationTonesFile,
  TonePatternsFile,
  LearningSignalsFile,
  ProfanityLexiconsFile,
  WeightModifiersFile,
  AttachmentOverridesFile,
  OnboardingPlaybookFile,
  SeverityCollaborationFile,
  SemanticThesaurusFile,
  ToneBucketMappingFile,
  UserPreferenceFile,
  AttachmentToneWeightsFile
} from '../types/dataTypes';

class DataLoaderService {
  private cache: DataCache = {};
  private dataPath: string;
  private initialized: boolean = false;

  constructor() {
    // The data folder is at the root of the unsaid-backend project
    // From api/_lib/services/, the data folder is at ../../../data/
    const possiblePaths = [
      path.resolve(__dirname, '../../../data'),     // api/_lib/services/ -> data/
      path.resolve(__dirname, '../../../../data'),  // Alternative nesting
      path.resolve(process.cwd(), 'data'),          // From project root
      path.resolve('/vercel/path0', 'data'),        // Vercel serverless path
      path.resolve(process.env.LAMBDA_TASK_ROOT || process.cwd(), 'data')
    ];
    
    // Find the first path that exists
    this.dataPath = possiblePaths.find(p => {
      try {
        return fs.existsSync(p);
      } catch {
        return false;
      }
    }) || possiblePaths[0];
    
    logger.info(`DataLoader initialized with path: ${this.dataPath}`);
    logger.info(`Available paths checked: ${possiblePaths.join(', ')}`);
    logger.info(`Data path exists: ${fs.existsSync(this.dataPath)}`);
    
    // List files in the data directory for debugging
    const VERBOSE_DATA_LOGS = process.env.VERBOSE_DATA_LOGS === '1';
    if (VERBOSE_DATA_LOGS) {
      try {
        if (fs.existsSync(this.dataPath)) {
          const files = fs.readdirSync(this.dataPath);
          logger.info(`Files in data directory: ${files.join(', ')}`);
        }
      } catch (err) {
        logger.warn(`Could not list files in data directory: ${err}`);
      }
    }

    // Pre-initialize synchronously to avoid async issues
    this.initializeSync();
  }

  private readJsonSafe<T>(filename: string, fallback: T): T {
    try {
      const filepath = path.join(this.dataPath, filename);
      logger.debug(`Attempting to read: ${filepath}`);
      
      if (fs.existsSync(filepath)) {
        const content = fs.readFileSync(filepath, 'utf-8');
        const parsed = JSON.parse(content);
        logger.debug(`Successfully loaded ${filename} (${content.length} chars)`);
        return parsed;
      } else {
        logger.warn(`File not found: ${filepath}`);
        // List directory contents for debugging
        const VERBOSE_DATA_LOGS = process.env.VERBOSE_DATA_LOGS === '1';
        if (VERBOSE_DATA_LOGS) {
          try {
            const dirContents = fs.readdirSync(this.dataPath);
            logger.info(`Data directory contents: ${dirContents.join(', ')}`);
          } catch (dirError) {
            logger.error(`Cannot read data directory ${this.dataPath}:`, dirError);
          }
        }
        return fallback;
      }
    } catch (error) {
      logger.error(`Error loading ${filename} from ${this.dataPath}:`, error);
      return fallback;
    }
  }

  private loadAllIntoCache(): void {
    // Critical configs
    this.cache.attachmentLearning = this.readJsonSafe<AttachmentLearningConfig>(
      'attachment_learning.json',
      null as any
    );

    // ✅ Enhanced config now loaded in both sync & async paths
    this.cache.attachmentLearningEnhanced = this.readJsonSafe<any>(
      'attachment_learning_enhanced.json',
      null as any
    );

    // Standard data
    this.cache.therapyAdvice       = this.readJsonSafe<any>('therapy_advice.json',       { version: '0', items: [] });
    this.cache.contextClassifier   = this.readJsonSafe<any>('context_classifier.json',   { version: '0', contexts: [] });
    this.cache.toneTriggerWords    = this.readJsonSafe<any>('tone_triggerwords.json',    {
      version: '0',
      clear:   { triggerwords: [] },
      caution: { triggerwords: [] },
      alert:   { triggerwords: [] },
      engine:  { genericTokens: {}, bucketGuards: {}, contextScopes: {} },
      weights: { contextMultipliers: {} }
    });
    this.cache.intensityModifiers  = this.readJsonSafe<any>('intensity_modifiers.json',  { version: '0', modifiers: [] });
    this.cache.sarcasmIndicators   = this.readJsonSafe<any>('sarcasm_indicators.json',   { version: '0', sarcasm_indicators: [] });
    this.cache.negationIndicators  = this.readJsonSafe<any>('negation_indicators.json',  { version: '0', negation_indicators: [] });
    this.cache.phraseEdges         = this.readJsonSafe<any>('phrase_edges.json',         { version: '0', edges: [] });
    this.cache.evaluationTones     = this.readJsonSafe<any>('evaluation_tones.json',     { version: '0', tones: [] });
    this.cache.tonePatterns        = this.readJsonSafe<any>('tone_patterns.json',        { version: '0', patterns: [] });
    this.cache.learningSignals     = this.readJsonSafe<any>('learning_signals.json',     { version: '0', signals: [] });
    this.cache.negationPatterns    = this.readJsonSafe<any>('negation_patterns.json',    { version: '0', patterns: [] });
    this.cache.profanityLexicons   = this.readJsonSafe<any>('profanity_lexicons.json',   {
      version: '0',
      categories: [
        { id: 'mild',     severity: 'mild',     triggerWords: [] },
        { id: 'moderate', severity: 'moderate', triggerWords: [] },
        { id: 'strong',   severity: 'strong',   triggerWords: [] }
      ]
    });
    this.cache.weightModifiers     = this.readJsonSafe<any>('weight_modifiers.json',     { version: '0', modifiers: [] });
    this.cache.attachmentOverrides = this.readJsonSafe<any>('attachment_overrides.json', { version: '0', overrides: [] });
    this.cache.onboardingPlaybook  = this.readJsonSafe<any>('onboarding_playbook.json',  { version: '0', steps: [] });

    // Special/aliases
    this.cache.severityCollaboration = this.readJsonSafe<any>('severity_collaboration.json', { alert: { base: 0.55 }, caution: { base: 0.4 }, clear: { base: 0.35 } });
    this.cache.severityCollab        = this.cache.severityCollaboration; // keep alias
    this.cache.semanticThesaurus     = this.readJsonSafe<any>('semantic_thesaurus.json', null);

    this.cache.userPreferences       = this.readJsonSafe<any>('user_preference.json', { categories: {} });
    this.cache.guardrailConfig       = this.readJsonSafe<any>('guardrail_config.json', { blockedPatterns: [] });

    // No fallback on purpose
    this.cache.toneBucketMapping     = this.readJsonSafe<any>('tone_bucket_mapping.json', null);

    this.cache.attachmentToneWeights = this.readJsonSafe<any>('attachment_tone_weights.json', { version: '0', overrides: {} });
  }

  public initializeSync(): void {
    if (this.initialized) return;
    try {
      logger.info('Initializing data cache (sync)…');
      this.loadAllIntoCache();
      this.initialized = true;
      logger.info('Data cache initialized successfully (sync)');
      logger.info(`[tone-buckets] loaded=${!!this.getToneBucketMapping()}`);
    } catch (error) {
      logger.error('Failed to initialize data cache synchronously:', error);
      this.initialized = true; // avoid loops
    }
  }

  public async initialize(): Promise<void> {
    if (this.initialized) return;
    try {
      logger.info('Initializing data cache (async)…');
      this.loadAllIntoCache(); // same loader
      this.initialized = true;
      logger.info('Data cache initialized successfully');
      logger.info(`[tone-buckets] loaded=${!!this.getToneBucketMapping()}`);
    } catch (error) {
      logger.error('Failed to initialize data cache:', error);
      throw new Error(`DataLoader initialization failed: ${error}`);
    }
  }

  public isInitialized(): boolean {
    return this.initialized;
  }

  // Getters for each data type - using null fallbacks to match original JS behavior
  public getAttachmentLearning(): AttachmentLearningConfig | null {
    return this.cache.attachmentLearning || null;
  }

  public getAttachmentLearningEnhanced(): import('../types/dataTypes').DataCache['attachmentLearningEnhanced'] {
    return this.cache.attachmentLearningEnhanced || null;
  }

  public getTherapyAdvice(): TherapyAdviceFile {
    return this.cache.therapyAdvice || { version: '0', items: [] };
  }

  public getContextClassifier(): ContextClassifierFile {
    return this.cache.contextClassifier || { version: '0', contexts: [] };
  }

  public getToneTriggerWords(): ToneTriggerWordsFile {
    return this.cache.toneTriggerWords || {
      version: '0',
      clear:   { triggerwords: [] },
      caution: { triggerwords: [] },
      alert:   { triggerwords: [] },
      engine:  { genericTokens: {}, bucketGuards: {}, contextScopes: {} },
      weights: { contextMultipliers: {} }
    };
  }

  public getIntensityModifiers(): IntensityModifiersFile {
    return this.cache.intensityModifiers || { version: '0', modifiers: [] };
  }

  public getSarcasmIndicators(): SarcasmIndicatorsFile {
    return this.cache.sarcasmIndicators || { version: '0', sarcasm_indicators: [] };
  }

  public getNegationIndicators(): NegationIndicatorsFile {
    return this.cache.negationIndicators || { version: '0', negation_indicators: [] };
  }

  public getPhraseEdges(): PhraseEdgesFile {
    return this.cache.phraseEdges || { version: '0', edges: [] };
  }

  public getEvaluationTones(): EvaluationTonesFile {
    return this.cache.evaluationTones || { version: '0', tones: [] };
  }

  public getTonePatterns(): TonePatternsFile {
    return this.cache.tonePatterns || { version: '0', patterns: [] };
  }

  public getLearningSignals(): LearningSignalsFile {
    return this.cache.learningSignals || { version: '0', signals: [] };
  }

  public getNegationPatterns(): NegationPatternsFile {
    return this.cache.negationPatterns!;
  }

  public getProfanityLexicons(): ProfanityLexiconsFile {
    return this.cache.profanityLexicons || { 
      version: '0', 
      categories: [
        { id: 'mild',     severity: 'mild',     triggerWords: [] },
        { id: 'moderate', severity: 'moderate', triggerWords: [] },
        { id: 'strong',   severity: 'strong',   triggerWords: [] }
      ]
    };
  }

  public getWeightModifiers(): WeightModifiersFile {
    return this.cache.weightModifiers || { version: '0', modifiers: [] };
  }

  public getAttachmentOverrides(): AttachmentOverridesFile {
    return this.cache.attachmentOverrides || { version: '0', overrides: [] };
  }

  public getOnboardingPlaybook(): OnboardingPlaybookFile {
    return this.cache.onboardingPlaybook || { version: '0', steps: [] };
  }

  public getSeverityCollaboration(): SeverityCollaborationFile {
    return this.cache.severityCollaboration || { alert: { base: 0.55 }, caution: { base: 0.4 }, clear: { base: 0.35 } };
  }

  public getSemanticThesaurus(): SemanticThesaurusFile | null {
    return this.cache.semanticThesaurus || null; // Return null if not loaded - enables optional feature
  }

  public getUserPreferences(): UserPreferenceFile {
    return this.cache.userPreferences || { categories: {} };
  }

  public getGuardrailConfig(): import('../types/dataTypes').DataCache['guardrailConfig'] {
    return this.cache.guardrailConfig || { blockedPatterns: [] };
  }

  public getToneBucketMapping(): import('../types/dataTypes').DataCache['toneBucketMapping'] {
    // Return exactly what's loaded. If the file is missing, this is null.
    return this.cache.toneBucketMapping ?? null;
  }

  public getAttachmentToneWeights(): AttachmentToneWeightsFile {
    return this.cache.attachmentToneWeights || { version: '0', overrides: {} };
  }

  // Utility methods for common access patterns
  public get(key: string): any {
    if (key === 'toneBucketMap') return this.cache.toneBucketMapping ?? null;
    if (key === 'severityCollab') return this.cache.severityCollaboration ?? null;
    return (this.cache as any)[key] ?? null;
  }

  // Refresh data cache
  public async refresh(): Promise<void> {
    this.initialized = false;
    this.cache = {};
    await this.initialize();
  }

  // Get all cached data (for debugging)
  public getAllData(): DataCache {
    return { ...this.cache };
  }

  // Get data file status (for health checks)
  public getDataStatus(): Record<string, boolean> {
    const files = [
      'attachment_learning.json',
      'attachment_learning_enhanced.json', 
      'therapy_advice.json',
      'context_classifier.json',
      'tone_triggerwords.json',
      'intensity_modifiers.json',
      'sarcasm_indicators.json',
      'negation_indicators.json',
      'phrase_edges.json',
      'evaluation_tones.json',
      'tone_patterns.json',
      'learning_signals.json',
      'negation_patterns.json',
      'profanity_lexicons.json',
      'weight_modifiers.json',
      'attachment_overrides.json',
      'attachment_tone_weights.json',
      'onboarding_playbook.json',
      'severity_collaboration.json',
      'semantic_thesaurus.json',
      'user_preference.json',
      'guardrail_config.json',
      'tone_bucket_mapping.json'
    ];

    const status: Record<string, boolean> = {};
    files.forEach(file => {
      const filepath = path.join(this.dataPath, file);
      status[file] = fs.existsSync(filepath);
    });

    return status;
  }

  // Enhanced methods for suggestions system
  getAllAdviceItems(): AdviceItem[] {
    const db = this.get('therapyAdvice');
    return normalizeAdvice(db);
  }
}

// ============================
// Validation Schemas
// ============================
const AdviceItem = z.object({
  id: z.string(),
  advice: z.string().min(1),
  triggerTone: z.enum(['clear','caution','alert']).default('clear'),
  contexts: z.array(z.string()).default([]),
  attachmentStyles: z.array(z.enum(['secure','anxious','avoidant','disorganized'])).default([]),
  severityThreshold: z.record(z.enum(['clear','caution','alert']), z.number().min(0).max(1)).optional(),
  spacyLink: z.array(z.string()).optional(),
  contextLink: z.array(z.string()).optional(),
  boostSources: z.array(z.string()).optional(),
  styleTuning: z.record(z.string(), z.number()).optional(),
  // Optional processing fields
  __tokens: z.array(z.string()).optional(),
  __vector: z.array(z.number()).optional(),
  // allow your merged "keywords"
  keywords: z.array(z.string()).optional()
}).passthrough();

export type AdviceItem = z.infer<typeof AdviceItem>;

// ============================
// Normalization Functions
// ============================
const toArr = (v: any) => Array.isArray(v) ? v : (v == null ? [] : [v]);

export function normalizeAdvice(db: any): AdviceItem[] {
  // Handle both direct array format and object with items property
  const rawItems = Array.isArray(db) ? db : (db?.items ?? []);
  
  const items = rawItems.map((raw: any) => {
    const merged = {
      ...raw,
      keywords: [
        ...toArr(raw.keywords),
        ...toArr(raw.matchKeywords),
        ...toArr(raw.boostSources),
      ],
    };
    try {
      return AdviceItem.parse(merged);
    } catch (error) {
      logger.warn(`Failed to validate advice item ${raw.id}:`, error);
      // Return a safe fallback
      return AdviceItem.parse({
        id: raw.id || 'unknown',
        advice: raw.advice || 'No advice available',
        triggerTone: 'clear',
        contexts: [],
        attachmentStyles: [],
        keywords: []
      });
    }
  });
  
  logger.info(`Normalized ${items.length} advice items`);
  return items;
}

export const dataLoader = new DataLoaderService();