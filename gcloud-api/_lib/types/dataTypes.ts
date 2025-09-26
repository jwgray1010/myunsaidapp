// api/_lib/types/dataTypes.ts
// TypeScript interfaces for all JSON data structures

// === Attachment Learning Configuration ===
export interface AttachmentLearningConfig {
  version: string;
  notes: string;
  metadata: {
    researchBasis: string;
    lastUpdated: string;
    validationDataset: string;
    accuracy: string;
  };
  learningDays: number;
  styles: string[];
  scoring: {
    thresholds: {
      primary: number;
      secondary: number;
    };
    dailyLimit: number;
    decay: {
      factor: number;
      applyDaily: boolean;
    };
  };
  learningConfig: {
    styles: string[];
    minObservations: number;
    maxObservationsPerDay: number;
    contextualLearning: boolean;
    temporalAnalysis: boolean;
    adaptiveThresholds: boolean;
  };
  scoringAlgorithm: {
    method: string;
    components: Record<string, number>;
    thresholds: {
      primary: {
        base: number;
        adaptive_range: [number, number];
        confidence_required: number;
      };
      secondary: {
        base: number;
        adaptive_range: [number, number];
        confidence_required: number;
      };
    };
  };
  attachmentSignatures: Record<string, any>;
  contextualFactors: Record<string, any>;
  linguisticMarkers: Record<string, any>;
  temporalPatterns: Record<string, any>;
  adaptiveThresholds: Record<string, any>;
}

// === File Wrappers that mirror actual JSON structures ===
export interface TherapyAdviceFile {
  version: string;
  items: TherapyAdvice[];
}

export interface ContextClassifierFile {
  version?: string;
  // Some parts of the code expect .contexts and sometimes an engine block
  contexts: any[];           // keep wide; spaCy client treats these as config blobs
  engine?: Record<string, any>;
}

export interface ToneTriggerWordsFile {
  version?: string;
  engine?: any;
  weights?: any;
  triggerwords?: any[];
  triggers?: any[]; // Legacy alias support
  alert?: { triggerwords?: any[] };
  caution?: { triggerwords?: any[] };
  clear?: { triggerwords?: any[] };
}

export interface IntensityModifiersFile {
  version?: string;
  modifiers: any[]; // JSON-driven patterns of varying shapes
}

export interface SarcasmIndicatorsFile {
  version?: string;
  sarcasm_indicators?: any[];
  patterns?: any[]; // some code reads .patterns
}

export interface NegationIndicatorsFile {
  version?: string;
  negation_indicators?: any[];
  patterns?: any[]; // some code reads .patterns
}

export interface PhraseEdgesFile {
  version?: string;
  edges: Array<{ pattern: string; category?: string } & Record<string, any>>;
}

export interface EvaluationTonesFile {
  version?: string;
  tones: EvaluationTone[];
}

export interface TonePatternsFile {
  version?: string;
  patterns: TonePattern[];
}

export interface LearningSignalsFile {
  version?: string;
  signals: LearningSignal[];
}

export interface ProfanityLexiconsFile {
  version?: string;
  categories: Array<{
    id: string;
    severity: 'mild'|'moderate'|'strong'|'severe'|'extreme'; // keep wide
    triggerWords: string[];
  }>;
}

export interface NegationPatternsFile {
  version?: string;
  patterns: string[];
}

export interface WeightModifiersFile {
  version?: string;
  modifiers: WeightModifier[];
}

export interface AttachmentOverridesFile {
  version?: string;
  overrides: AttachmentOverride[];
}

export interface OnboardingPlaybookFile {
  version?: string;
  steps: OnboardingPlaybook[];
}

export interface SeverityCollaborationFile {
  alert:   { base: number };
  caution: { base: number };
  clear:   { base: number };
}

export interface SemanticThesaurusFile {
  version?: string;
  settings?: {
    normalize?: any;
    languages?: any;
    thresholds?: any;
    reverseRegisterRule?: any;
    ironySarcasm?: any;
  };
  clusters?: any[] | Record<string, any>;
  contexts?: any[];
  routing_matrix?: any;
  attachment_overrides?: any;
}

export interface ToneBucketMappingFile {
  version?: string;
  buckets?: ToneBucketMapping[];
  // some deployments provide a flat array; keep a union:
  // OR: ToneBucketMapping[]
}

export interface UserPreferenceFile {
  categories: Record<string, any>;
}

export interface AttachmentToneWeightsFile {
  version?: string;
  overrides: Record<string, any>;
}

export interface TherapyAdvice {
  id: string;
  advice: string;                 // micro-therapy tip, not a script
  triggerTone?: 'clear'|'caution'|'alert';
  contexts?: string[];            // e.g., ['conflict','planning','general']
  contextLink?: string[];         // include 'CTX_PATTERN' for pattern-aware items
  attachmentStyles?: Array<'anxious'|'avoidant'|'disorganized'|'secure'>;
  intents?: string[];             // e.g., ['reassure','boundary','repair','de-escalate']
  // NEW — additive fields
  patterns?: Array<'anxious.pattern'|'avoidant.pattern'|'disorganized.pattern'|'secure.pattern'>;
  styleTuning?: Partial<Record<'anxious'|'avoidant'|'disorganized'|'secure', number>>;
  severityThreshold?: Partial<Record<'clear'|'caution'|'alert', number>>;
  boostSources?: string[];
  tags?: string[];
  spacyLink?: string[];
  core_contexts?: string[];
  // optional indexing-time payloads:
  __tokens?: string[];
  __vector?: number[];
}

export interface TonePattern {
  id: string;
  tone: string;
  type: string;
  pattern: string;
  confidence: number;
  category: string;
  attachmentStyles: string[];
  styleWeight: Record<string, number>;
  spacyPattern?: any[];
  semanticVariants?: string[];
  contextualModifiers?: Record<string, number>;
  intensityMultiplier?: number;
}

export interface EvaluationTone {
  tone: string;
  description: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  color: string;
  emoji: string;
  attachmentRelevance: Record<string, number>;
  therapeuticPriority: number;
  interventionRequired: boolean;
  commonTriggers: string[];
  healingApproaches: string[];
}

export interface SemanticThesaurus {
  baseWord: string;
  synonyms: string[];
  emotionalVariants: Record<string, string[]>;
  intensityLevels: Record<string, string[]>;
  contextualAlternatives: Record<string, string[]>;
  attachmentStylePreferences: Record<string, string[]>;
}

export interface UserPreference {
  userId: string;
  communicationStyle: string;
  preferredToneRange: string[];
  avoidedTopics: string[];
  responseStyle: 'direct' | 'gentle' | 'balanced' | 'analytical';
  attachmentAwareness: boolean;
  personalityInsights: Record<string, any>;
  adaptationHistory: Record<string, any>;
}

export interface ContextClassifier {
  context: string;
  keywords: string[];
  patterns: string[];
  emotionalIndicators: string[];
  attachmentTriggers: Record<string, string[]>;
  appropriateResponses: string[];
  riskFactors: string[];
  therapeuticOpportunities: string[];
}

export interface IntensityModifier {
  modifier: string;
  type: 'amplifier' | 'diminisher' | 'neutral';
  baseMultiplier: number;
  contextualAdjustments: Record<string, number>;
  attachmentSpecific: Record<string, number>;
  linguisticVariants: string[];
}

export interface LearningSignal {
  signalType: string;
  indicators: string[];
  weight: number;
  attachmentRelevance: Record<string, number>;
  temporalDecay: number;
  contextualModifiers: Record<string, number>;
  validationCriteria: string[];
}

export interface GuardrailConfig {
  category: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  patterns: string[];
  blockedPhrases: string[];
  warningThresholds: Record<string, number>;
  allowedExceptions: string[];
  escalationProtocol: string[];
  therapeuticResponse: string[];
}

export interface OnboardingPlaybook {
  stage: string;
  objectives: string[];
  keyQuestions: string[];
  expectedOutcomes: string[];
  attachmentConsiderations: Record<string, string[]>;
  progressIndicators: string[];
  commonChallenges: string[];
  supportStrategies: string[];
}

export interface ToneBucketMapping {
  bucket: string;
  tones: string[];
  severity: number;
  therapeuticApproach: string;
  attachmentConsiderations: Record<string, string>;
  interventionTrigger: boolean;
  escalationPath: string[];
}

export interface NegationIndicator {
  indicator: string;
  type: 'explicit' | 'implicit' | 'contextual';
  strength: number;
  patterns: string[];
  exceptions: string[];
}

export interface NegationPattern {
  pattern: string;
  type: 'regex' | 'phrase' | 'keyword';
  negationType: 'complete' | 'partial' | 'conditional';
  confidence: number;
  contextualRules: string[];
}

export interface ProfanityLexicon {
  word: string;
  severity: 'mild' | 'moderate' | 'severe' | 'extreme';
  category: string;
  variants: string[];
  contextualModifiers: Record<string, number>;
}

export interface SarcasmIndicator {
  indicator: string;
  type: 'verbal' | 'contextual' | 'punctuation';
  confidence: number;
  patterns: string[];
  attachmentRelevance: Record<string, number>;
}

export interface WeightModifier {
  modifier: string;
  category: string;
  baseWeight: number;
  contextualAdjustments: Record<string, number>;
  attachmentSpecific: Record<string, number>;
}

export interface AttachmentOverride {
  attachmentStyle: string;
  scenario: string;
  originalResponse: string;
  overrideResponse: string;
  conditions: string[];
  priority: number;
}

export interface PhraseEdge {
  fromPhrase: string;
  toPhrase: string;
  relationshipType: string;
  weight: number;
  context: string[];
  attachmentRelevance: Record<string, number>;
}

export interface ToneTriggerWord {
  word: string;
  targetTone: string;
  weight: number;
  variants: string[];
  contextualModifiers: Record<string, number>;
}

export interface SeverityCollaboration {
  level: string;
  description: string;
  interventions: string[];
  escalationThreshold: number;
  therapeuticApproach: string[];
}

// Data loading utilities
export interface DataCache {
  attachmentLearning?: AttachmentLearningConfig | null;

  // ✅ Analyzer expects AnalysisConfig here, NOT AttachmentLearningConfig
  attachmentLearningEnhanced?: import('../services/advancedLinguisticAnalyzer').AnalysisConfig | null;

  therapyAdvice?: TherapyAdviceFile;
  tonePatterns?: TonePatternsFile;
  evaluationTones?: EvaluationTonesFile;
  semanticThesaurus?: SemanticThesaurusFile | null;

  userPreferences?: UserPreferenceFile;
  contextClassifier?: ContextClassifierFile;
  intensityModifiers?: IntensityModifiersFile;
  learningSignals?: LearningSignalsFile;
  guardrailConfig?: GuardrailConfig[] | { blockedPatterns: string[] }; // keep wide for current use
  onboardingPlaybook?: OnboardingPlaybookFile;

  toneBucketMapping?: ToneBucketMappingFile | ToneBucketMapping[] | null;

  negationIndicators?: NegationIndicatorsFile;
  negationPatterns?: NegationPatternsFile;
  profanityLexicons?: ProfanityLexiconsFile;
  sarcasmIndicators?: SarcasmIndicatorsFile;
  weightModifiers?: WeightModifiersFile;

  attachmentOverrides?: AttachmentOverridesFile;
  attachmentToneWeights?: AttachmentToneWeightsFile;

  phraseEdges?: PhraseEdgesFile;
  toneTriggerWords?: ToneTriggerWordsFile;

  severityCollaboration?: SeverityCollaborationFile;
  severityCollab?: SeverityCollaborationFile; // kept as alias because loader sets both

  weightProfiles?: { version?: string; profiles: Record<string, any> };
}