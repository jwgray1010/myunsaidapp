// api/cron/validate-data.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { withMethods, withErrorHandling, withLogging } from '../_lib/wrappers';
import { success, error as httpError } from '../_lib/http';
import { dataLoader } from '../_lib/services/dataLoader';
import { logger } from '../_lib/logger';

interface ValidationResult {
  file: string;
  valid: boolean;
  errors: string[];
  recordCount?: number;
  lastModified?: string;
}

interface DataValidationReport {
  timestamp: string;
  totalFiles: number;
  validFiles: number;
  invalidFiles: number;
  results: ValidationResult[];
  overallStatus: 'healthy' | 'warning' | 'error';
}

function isAuthorizedCron(req: VercelRequest): boolean {
  const token = (req.query?.auth_token || req.query?.token || '').toString();
  const expected = process.env.CRON_TOKEN || 'f47ac10b-58cc-4372-a567-0e02b2c3d479';
  return Boolean(expected) && token === expected;
}

const handler = async (req: VercelRequest, res: VercelResponse) => {
  if (!isAuthorizedCron(req)) {
    return httpError(res, 'Unauthorized cron', 401);
  }

  const startTime = Date.now();

  try {
    logger.info('Starting data validation cron job');

    // Ensure DataLoader is ready. Your DataLoader constructor does a sync init,
    // but keep this guard so we return a proper response if something went wrong.
    if (!dataLoader.isInitialized()) {
      logger.warn('DataLoader not initialized in validate-data cron');
      return httpError(res, 'DataLoader not initialized', 503);
    }

    const results: ValidationResult[] = [];

    // Each entry includes: how to get data + how to validate shape
    const validationChecks: Array<{
      name: string;
      getter: () => any;
      validate: (data: any) => { errors: string[]; recordCount?: number };
    }> = [
      {
        name: 'attachment_learning.json',
        getter: () => dataLoader.getAttachmentLearning(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) errors.push('Data not loaded or null');
          return { errors, recordCount: d ? 1 : 0 };
        }
      },
      {
        name: 'therapy_advice.json',
        getter: () => dataLoader.getTherapyAdvice(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle direct array format or {version, items} format
          const items = Array.isArray(d) ? d : (Array.isArray(d?.items) ? d.items : []);
          if (items.length === 0) errors.push('No advice items loaded');
          // Spot-check first item fields if present
          const sample = items[0];
          if (sample && (!sample.advice || !sample.triggerTone)) {
            errors.push('Missing required fields: advice, triggerTone on first item');
          }
          return { errors, recordCount: items.length };
        }
      },
      {
        name: 'tone_patterns.json',
        getter: () => dataLoader.getTonePatterns(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle {patterns: [...]} format or direct array
          const patterns = Array.isArray(d?.patterns) ? d.patterns : (Array.isArray(d) ? d : []);
          if (patterns.length === 0) errors.push('No tone patterns loaded');
          const sample = patterns[0];
          if (sample && (!sample.tone || !sample.pattern)) {
            errors.push('Missing required fields: tone, pattern on first item');
          }
          return { errors, recordCount: patterns.length };
        }
      },
      {
        name: 'evaluation_tones.json',
        getter: () => dataLoader.getEvaluationTones(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle {tones: [...]} format or direct array
          const tones = Array.isArray(d?.tones) ? d.tones : (Array.isArray(d) ? d : []);
          if (tones.length === 0) errors.push('No evaluation tones loaded');
          return { errors, recordCount: tones.length };
        }
      },
      {
        name: 'semantic_thesaurus.json',
        getter: () => dataLoader.getSemanticThesaurus(), // may be null (optional)
        validate: (d) => {
          const errors: string[] = [];
          if (d == null) {
            // optional file: treat as valid but note it's missing
            return { errors, recordCount: 0 };
          }
          const clusters = d?.clusters || {};
          if (Object.keys(clusters).length === 0) errors.push('No semantic clusters found');
          return { errors, recordCount: Object.keys(clusters).length };
        }
      },
      {
        name: 'context_classifier.json',
        getter: () => dataLoader.getContextClassifier(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle {contexts: [...]} format or object with version
          const contexts = Array.isArray(d?.contexts) ? d.contexts : (d?.version ? [] : []);
          if (!d?.version && contexts.length === 0) errors.push('No contexts loaded');
          return { errors, recordCount: d?.version ? 1 : contexts.length };
        }
      },
      {
        name: 'intensity_modifiers.json',
        getter: () => dataLoader.getIntensityModifiers(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle direct array format or {modifiers: [...]} format
          const modifiers = Array.isArray(d) ? d : (Array.isArray(d?.modifiers) ? d.modifiers : []);
          if (modifiers.length === 0) errors.push('No intensity modifiers loaded');
          return { errors, recordCount: modifiers.length };
        }
      },
      {
        name: 'learning_signals.json',
        getter: () => dataLoader.getLearningSignals(),
        validate: (d) => {
          const errors: string[] = [];
          // Handle object with version and signals array
          const signals = Array.isArray(d?.signals) ? d.signals : [];
          if (!d?.version) errors.push('Missing version field');
          if (signals.length === 0) errors.push('No learning signals loaded');
          return { errors, recordCount: signals.length || (d?.version ? 1 : 0) };
        }
      },
      {
        name: 'guardrail_config.json',
        getter: () => dataLoader.getGuardrailConfig(), // {blockedPatterns: []}
        validate: (d) => {
          const errors: string[] = [];
          if (!d) errors.push('Config not loaded');
          return { errors, recordCount: d ? 1 : 0 };
        }
      },
      {
        name: 'tone_bucket_mapping.json',
        getter: () => dataLoader.getToneBucketMapping(), // {default, contextOverrides, intensityShifts}
        validate: (d) => {
          const errors: string[] = [];
          if (!d?.default) errors.push('Missing default mapping');
          return { errors, recordCount: d?.default ? Object.keys(d.default).length : 0 };
        }
      },
      {
        name: 'negation_indicators.json',
        getter: () => dataLoader.getNegationIndicators(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          const items = Array.isArray(d?.negation_indicators)
            ? d.negation_indicators
            : Array.isArray(d?.patterns)
              ? d.patterns
              : [];
          if (!d?.version) errors.push('Missing version field');
          if (items.length === 0) errors.push('No negation indicators loaded');
          return { errors, recordCount: items.length };
        }
      },
      {
        name: 'profanity_lexicons.json',
        getter: () => dataLoader.getProfanityLexicons(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          // Handle {rules: [...]} format or {words: [...]} format
          const items = Array.isArray(d?.rules) ? d.rules : (Array.isArray(d?.words) ? d.words : []);
          if (!d?.version) errors.push('Missing version field');
          if (items.length === 0) errors.push('No profanity words loaded');
          return { errors, recordCount: items.length };
        }
      },
      {
        name: 'sarcasm_indicators.json',
        getter: () => dataLoader.getSarcasmIndicators(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          const items = Array.isArray(d?.sarcasm_indicators) ? d.sarcasm_indicators : [];
          if (!d?.version) errors.push('Missing version field');
          if (items.length === 0) errors.push('No sarcasm indicators loaded');
          return { errors, recordCount: items.length };
        }
      },
      {
        name: 'weight_modifiers.json',
        getter: () => dataLoader.getWeightModifiers(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          // Handle {byContext: {...}} format or {modifiers: [...]} format
          const contextCount = d?.byContext ? Object.keys(d.byContext).length : 0;
          const modifiers = Array.isArray(d?.modifiers) ? d.modifiers : [];
          const totalItems = Math.max(contextCount, modifiers.length);
          if (!d?.version) errors.push('Missing version field');
          if (totalItems === 0) errors.push('No weight modifiers loaded');
          return { errors, recordCount: totalItems };
        }
      },
      {
        name: 'attachment_overrides.json',
        getter: () => dataLoader.getAttachmentOverrides(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          const applyOrder = Array.isArray(d?.applyOrder) ? d.applyOrder : [];
          if (applyOrder.length === 0) errors.push('No apply order defined');
          return { errors, recordCount: applyOrder.length };
        }
      },
      {
        name: 'attachment_tone_weights.json',
        getter: () => dataLoader.getAttachmentToneWeights(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          // Handle {applyOrder: [...]} or {weights: {...}} format
          const applyOrder = Array.isArray(d?.applyOrder) ? d.applyOrder : [];
          const weights = d?.weights || {};
          const totalItems = Math.max(applyOrder.length, Object.keys(weights).length);
          if (totalItems === 0) errors.push('No attachment tone weights defined');
          return { errors, recordCount: totalItems };
        }
      },
      {
        name: 'negation_patterns.json',
        getter: () => dataLoader.getNegationPatterns(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          const patterns = Array.isArray(d?.patterns) ? d.patterns : [];
          if (patterns.length === 0) errors.push('No negation patterns loaded');
          return { errors, recordCount: patterns.length };
        }
      },
      {
        name: 'phrase_edges.json',
        getter: () => dataLoader.getPhraseEdges(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          const edges = Array.isArray(d?.edges) ? d.edges : [];
          if (edges.length === 0) errors.push('No phrase edges loaded');
          return { errors, recordCount: edges.length };
        }
      },
      {
        name: 'severity_collaboration.json',
        getter: () => dataLoader.getSeverityCollaboration(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          // Handle complex structure - count sections or rules
          const rules = Array.isArray(d?.rules) ? d.rules : 
                       Array.isArray(d?.levels) ? d.levels :
                       Array.isArray(d?.items) ? d.items : [];
          const sectionCount = d ? Object.keys(d).filter(k => k !== 'version' && k !== 'notes').length : 0;
          const totalItems = Math.max(rules.length, sectionCount);
          if (totalItems === 0) errors.push('No severity collaboration rules loaded');
          return { errors, recordCount: totalItems };
        }
      },
      {
        name: 'tone_triggerwords.json',
        getter: () => dataLoader.getToneTriggerWords(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          if (!d?.engine) errors.push('Missing engine configuration');
          // Handle {clear: {triggerwords: []}, caution: {triggerwords: []}, alert: {triggerwords: []}} format
          const clearWords = Array.isArray(d?.clear?.triggerwords) ? d.clear.triggerwords : [];
          const cautionWords = Array.isArray(d?.caution?.triggerwords) ? d.caution.triggerwords : [];
          const alertWords = Array.isArray(d?.alert?.triggerwords) ? d.alert.triggerwords : [];
          const totalWords = clearWords.length + cautionWords.length + alertWords.length;
          if (totalWords === 0) errors.push('No tone triggerwords loaded');
          return { errors, recordCount: totalWords };
        }
      },
      {
        name: 'user_preference.json',
        getter: () => dataLoader.getUserPreferences(),
        validate: (d) => {
          const errors: string[] = [];
          if (!d) {
            errors.push('Data not loaded or null');
            return { errors, recordCount: 0 };
          }
          if (!d?.version) errors.push('Missing version field');
          // Handle {categories: {...}} or {preferences: {...}} format
          const preferences = d?.preferences || {};
          const categories = d?.categories || {};
          const totalItems = Math.max(Object.keys(preferences).length, Object.keys(categories).length);
          if (totalItems === 0) errors.push('No user preferences defined');
          return { errors, recordCount: totalItems };
        }
      }
    ];

    for (const check of validationChecks) {
      try {
        const data = check.getter();
        const { errors, recordCount } = check.validate(data);
        results.push({
          file: check.name,
          valid: errors.length === 0,
          errors,
          recordCount
        });
      } catch (e: any) {
        results.push({
          file: check.name,
          valid: false,
          errors: [`Validation error: ${e?.message || 'Unknown error'}`]
        });
      }
    }

    const validFiles = results.filter(r => r.valid).length;
    const invalidFiles = results.length - validFiles;
    const totalFiles = results.length;

    let overallStatus: 'healthy' | 'warning' | 'error' = 'healthy';
    if (invalidFiles > 0) {
      overallStatus = invalidFiles > totalFiles * 0.3 ? 'error' : 'warning';
    }

    const report: DataValidationReport = {
      timestamp: new Date().toISOString(),
      totalFiles,
      validFiles,
      invalidFiles,
      results,
      overallStatus
    };

    const processingTime = Date.now() - startTime;

    logger.info('Data validation completed', {
      processingTimeMs: processingTime,
      totalFiles,
      validFiles,
      invalidFiles,
      status: overallStatus
    });

    if (overallStatus !== 'healthy') {
      const invalidResults = results.filter(r => !r.valid);
      logger.warn('Data validation issues found', { invalidResults });
    }

    return success(
      res,
      {
        report,
        metadata: {
          processingTimeMs: processingTime,
          cronJob: 'validate-data',
          version: '1.0.1'
        }
      },
      200
    );
  } catch (error) {
    logger.error('Data validation cron job failed:', error);
    throw error;
  }
};

export default withErrorHandling(
  withLogging(
    // Cron uses GET; no CORS wrapper needed here
    withMethods(['GET'], handler)
  )
);
