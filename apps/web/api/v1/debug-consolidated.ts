// api/v1/debug-consolidated.ts
// Consolidated debug endpoint combining debug.ts and tone-debug.ts
import type { VercelRequest, VercelResponse } from '@vercel/node';
import * as fs from 'fs';
import * as path from 'path';
import { logger } from '../_lib/logger';
import { dataLoader } from '../_lib/services/dataLoader';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const { type } = req.query;

  try {
    // Route to specific debug functionality based on query parameter
    switch (type) {
      case 'system':
        return handleSystemDebug(req, res);
      case 'tone':
        return handleToneDebug(req, res);
      default:
        return res.status(200).json({
          message: 'Consolidated debug endpoint',
          availableTypes: ['system', 'tone'],
          usage: 'Add ?type=<debug-type> to run specific debug tests',
          timestamp: new Date().toISOString()
        });
    }
  } catch (error) {
    logger.error('Error in consolidated debug handler:', error);
    res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    });
  }
}

// System debug functionality (from debug.ts)
async function handleSystemDebug(req: VercelRequest, res: VercelResponse) {
  try {
    const cwd = process.cwd();
    const apiDir = path.join(cwd, 'api');
    const dataDir = path.join(cwd, 'data');
    const libDir = path.join(cwd, 'api', '_lib');
    
    // Check what directories exist
    const cwdExists = fs.existsSync(cwd);
    const apiExists = fs.existsSync(apiDir);
    const dataExists = fs.existsSync(dataDir);
    const libExists = fs.existsSync(libDir);
    
    // List contents of current directory
    let cwdContents: string[] = [];
    try {
      cwdContents = fs.readdirSync(cwd);
    } catch (e) {
      cwdContents = [`Error: ${e}`];
    }
    
    // List contents of data directory if it exists
    let dataContents: string[] = [];
    if (dataExists) {
      try {
        dataContents = fs.readdirSync(dataDir);
      } catch (e) {
        dataContents = [`Error: ${e}`];
      }
    }
    
    // List contents of api directory if it exists
    let apiContents: string[] = [];
    if (apiExists) {
      try {
        apiContents = fs.readdirSync(apiDir);
      } catch (e) {
        apiContents = [`Error: ${e}`];
      }
    }
    
    res.status(200).json({
      success: true,
      data: {
        cwd,
        paths: {
          api: apiDir,
          data: dataDir,
          lib: libDir
        },
        exists: {
          cwd: cwdExists,
          api: apiExists,
          data: dataExists,
          lib: libExists
        },
        contents: {
          cwd: cwdContents,
          data: dataContents,
          api: apiContents
        },
        __dirname,
        __filename: __filename || 'not available'
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    });
  }
}

// Tone debug functionality (from tone-debug.ts)
async function handleToneDebug(req: VercelRequest, res: VercelResponse) {
  try {
    const text = req.body?.text || "I feel so overwhelmed and stressed out";
    logger.info('Starting tone debug with text:', text);
    
    // Force initialize dataLoader
    if (!dataLoader.isInitialized()) {
      await dataLoader.initialize();
    }
    
    // Test each data source the tone analysis needs
    const tonePatterns = dataLoader.getTonePatterns();
    const evaluationTones = dataLoader.getEvaluationTones();
    const intensityModifiers = dataLoader.getIntensityModifiers();
    const attachmentLearning = dataLoader.getAttachmentLearning();
    const toneTriggerWords = dataLoader.getToneTriggerWords();
    
    logger.info('Data loaded successfully');
    
    // Test the specific data structures
    const debugInfo = {
      tonePatterns: {
        type: Array.isArray(tonePatterns) ? 'array' : typeof tonePatterns,
        keys: tonePatterns ? Object.keys(tonePatterns) : [],
        patternsArray: tonePatterns?.patterns ? Array.isArray(tonePatterns.patterns) : false,
        patternsLength: tonePatterns?.patterns?.length || 0
      },
      evaluationTones: {
        type: Array.isArray(evaluationTones) ? 'array' : typeof evaluationTones,
        keys: evaluationTones ? Object.keys(evaluationTones) : [],
        tonesArray: evaluationTones?.tones ? Array.isArray(evaluationTones.tones) : false,
        tonesLength: evaluationTones?.tones?.length || 0
      },
      intensityModifiers: {
        type: Array.isArray(intensityModifiers) ? 'array' : typeof intensityModifiers,
        keys: intensityModifiers ? Object.keys(intensityModifiers) : [],
        modifiersArray: intensityModifiers?.modifiers ? Array.isArray(intensityModifiers.modifiers) : false,
        modifiersLength: intensityModifiers?.modifiers?.length || 0
      },
      attachmentLearning: {
        type: Array.isArray(attachmentLearning) ? 'array' : typeof attachmentLearning,
        keys: attachmentLearning ? Object.keys(attachmentLearning) : [],
        hasScoring: !!attachmentLearning?.scoring,
        hasThresholds: !!attachmentLearning?.scoring?.thresholds
      },
      toneTriggerWords: {
        type: Array.isArray(toneTriggerWords) ? 'array' : typeof toneTriggerWords,
        keys: toneTriggerWords ? Object.keys(toneTriggerWords) : [],
        triggersArray: toneTriggerWords?.triggers ? Array.isArray(toneTriggerWords.triggers) : false,
        triggersLength: toneTriggerWords?.triggers?.length || 0
      }
    };
    
    // Now try to import and test the toneAnalysisService step by step
    logger.info('Importing toneAnalysisService...');
    const { toneAnalysisService } = await import('../_lib/services/toneAnalysis');
    
    logger.info('Testing ensureDataLoaded...');
    await (toneAnalysisService as any).ensureDataLoaded();
    
    res.status(200).json({
      success: true,
      text,
      debugInfo,
      message: 'All data structures verified and toneAnalysisService imported successfully'
    });
    
  } catch (error) {
    logger.error('Tone debug error:', error);
    res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error',
      stack: error instanceof Error ? error.stack : undefined
    });
  }
}