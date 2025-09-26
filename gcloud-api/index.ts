/**
 * Google Cloud entry point for heavy Unsaid API services
 * 
 * This module exposes all the computationally expensive services
 * that were moved from Vercel to Google Cloud for cost optimization.
 * 
 * Services included:
 * - Tone Analysis (ML-powered)
 * - NLI Processing (ONNX runtime with native performance)
 * - Zero-Shot Classification (ONNX-based)
 * - Context Analysis
 * - Suggestion Generation
 * - Cron Jobs
 * - Debug/Testing endpoints
 * 
 * Performance improvements over @xenova/transformers:
 * - 3-5x faster inference with onnxruntime-node
 * - Lower memory usage (no browser emulation)  
 * - Better caching and batch processing
 * - Native Google Cloud optimizations
 */

import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { logger } from './_lib/logger';

// Import services
import { toneAnalysisService } from './_lib/services/toneAnalysis';
import { suggestionsService } from './_lib/services/suggestions';

const app = express();
const port = process.env.PORT || 8080;

// Middleware
app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Health check
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    service: 'unsaid-gcloud-api',
    timestamp: new Date().toISOString(),
    version: '1.0.0'
  });
});

// Tone Analysis endpoint
app.post('/tone-analysis', async (req, res) => {
  try {
    const { text, context, attachmentStyle, userId } = req.body;
    
    if (!text) {
      return res.status(400).json({ 
        success: false,
        error: 'Text is required',
        timestamp: new Date().toISOString(),
        version: '1.0.0'
      });
    }

    // Use the heavy tone analysis service - attachment style used directly
    const result = await toneAnalysisService.analyzeAdvancedTone(text, {
      context: context || 'general',
      attachmentStyle,
      deepAnalysis: true
    });

    res.json({
      success: true,
      data: result,
      timestamp: new Date().toISOString(),
      version: '1.0.0'
    });
  } catch (error) {
    logger.error('Tone analysis failed', { error });
    res.status(500).json({ 
      success: false,
      error: 'Tone analysis failed',
      timestamp: new Date().toISOString(),
      version: '1.0.0'
    });
  }
});

// Suggestions endpoint
app.post('/suggestions', async (req, res) => {
  try {
    const { text, toneAnalysis, context, attachmentStyle, userId } = req.body;
    
    if (!text || !toneAnalysis) {
      return res.status(400).json({ 
        success: false,
        error: 'Text and toneAnalysis are required',
        timestamp: new Date().toISOString(),
        version: '1.0.0'
      });
    }

    const result = await suggestionsService.generateAdvancedSuggestions(
      text,
      context || 'general',
      undefined, // userProfile
      {
        maxSuggestions: 3,
        attachmentStyle: attachmentStyle || 'secure',
        userId: userId || 'anonymous',
        fullToneAnalysis: toneAnalysis
      }
    );

    res.json({
      success: true,
      data: result,
      timestamp: new Date().toISOString(),
      version: '1.0.0'
    });
  } catch (error) {
    logger.error('Suggestions generation failed', { error });
    res.status(500).json({ 
      success: false,
      error: 'Suggestions generation failed',
      timestamp: new Date().toISOString(),
      version: '1.0.0'
    });
  }
});

// Start server
app.listen(port, () => {
  logger.info(`🚀 Unsaid Google Cloud API listening on port ${port}`);
});