// api/_lib/services/communicatorProfile.ts
import { logger } from '../logger';
import { dataLoader } from './dataLoader';
import { normalizeScores, defaultPriorWeight } from '../utils/priors';

export interface AttachmentEstimate {
  primary: 'anxious' | 'avoidant' | 'disorganized' | 'secure' | null;
  secondary: string | null;
  windowComplete: boolean;
  confidence: number;
  scores: {
    anxious: number;
    avoidant: number;
    disorganized: number;
    secure: number;
  };
  daysObserved: number;
  totalSignals: number;
}

export interface ProfileData {
  userId: string;
  attachmentStyle?: string;
  communicationHistory: Array<{
    text: string;
    context: string;
    tone: string;
    timestamp: Date;
  }>;
  learningSignals: Record<string, any>;
  learningSignalConfigs: Record<string, any>;
  preferences: {
    contexts: string[];
    suggestionTypes: string[];
    sensitivity: number;
  };
}

export class CommunicatorProfile {
  private userId: string;
  private data: ProfileData;

  constructor(options: { 
    userId: string; 
    storage?: any; 
  }) {
    this.userId = options.userId;
    this.data = {
      userId: this.userId,
      communicationHistory: [],
      learningSignals: {},
      learningSignalConfigs: {},
      preferences: {
        contexts: ['general'],
        suggestionTypes: ['advice', 'empathy'],
        sensitivity: 0.5
      }
    };
  }

  async init(): Promise<void> {
    try {
      // DataLoader is now pre-initialized synchronously
      if (!dataLoader.isInitialized()) {
        logger.warn('DataLoader not initialized in CommunicatorProfile');
        return;
      }

      // Load learning signal configurations from dataLoader
      const learningSignalsData = dataLoader.getLearningSignals();
      const learningSignals = learningSignalsData?.signals || [];
      
      // Store signal configurations separately from user counters
      this.data.learningSignalConfigs = learningSignals.reduce((acc: Record<string, any>, signal: any) => {
        acc[signal.signalType] = signal;
        return acc;
      }, {} as Record<string, any>);
      
      // Initialize user counters with zeros for session-based processing
      // Real learning data comes from device storage via API calls
      const baseCounters = { 
        anxious: 0, avoidant: 0, disorganized: 0, secure: 0, 
        daysObserved: 0, totalCommunications: 0, windowComplete: false 
      };
      this.data.learningSignals = baseCounters;

      logger.info('CommunicatorProfile initialized for session processing', { 
        userId: this.userId,
        signalConfigCount: learningSignals.length
      });
    } catch (error) {
      logger.error('Failed to initialize CommunicatorProfile:', error);
      throw error;
    }
  }

  getAttachmentEstimate(): AttachmentEstimate {
    const attachmentLearning = dataLoader.getAttachmentLearning();
    if (!attachmentLearning) {
      throw new Error('attachment_learning.json is required (no fallback)');
    }

    const thresholds = attachmentLearning.scoring?.thresholds;
    if (!thresholds) {
      throw new Error('attachment_learning.json missing scoring.thresholds');
    }

    // Use actual persisted learning data
    const daysObserved = Number(this.data.learningSignals.daysObserved || 0);
    const totalSignals = Number(this.data.learningSignals.totalCommunications || 0);
    const learningDays = attachmentLearning.learningDays || 7;

    // Server signals raw extraction from persisted data
    const s: any = this.data.learningSignals || {};
    const attachmentSignals = {
      anxious: Number(s.anxious || 0),
      avoidant: Number(s.avoidant || 0),
      disorganized: Number(s.disorganized || 0),
      secure: Number(s.secure || 0)
    };
    
    const attachmentTotal = attachmentSignals.anxious + attachmentSignals.avoidant + 
                          attachmentSignals.disorganized + attachmentSignals.secure;

    // If no learning data and no prior → empty estimate
    const localPrior: any = (this as any).data.localPrior;
    if (attachmentTotal < 1e-9 && !localPrior) {
      return { 
        primary: null, 
        secondary: null, 
        windowComplete: Boolean(s.windowComplete),
        confidence: 0,
        scores: { anxious: 0, avoidant: 0, disorganized: 0, secure: 0 },
        daysObserved: Math.round(daysObserved * 10) / 10, // Round to 1 decimal
        totalSignals
      };
    }

    const serverNorm = normalizeScores(attachmentSignals);

    const priorScores = localPrior?.scores ? normalizeScores(localPrior.scores) : null;
    const wPrior = priorScores ? defaultPriorWeight(daysObserved, learningDays) : 0;
    const wServer = 1 - wPrior;

    const combined = normalizeScores({
      anxious: (priorScores?.anxious||0)*wPrior + serverNorm.anxious*wServer,
      avoidant: (priorScores?.avoidant||0)*wPrior + serverNorm.avoidant*wServer,
      disorganized: (priorScores?.disorganized||0)*wPrior + serverNorm.disorganized*wServer,
      secure: (priorScores?.secure||0)*wPrior + serverNorm.secure*wServer,
    });

    const ranked = (Object.entries(combined) as Array<[string, number]>).sort((a,b)=> b[1]-a[1]);
    const [primaryStyle, primaryScore] = ranked[0];
    const [secondaryStyle, secondaryScore] = ranked[1];

    const primary = primaryScore >= (thresholds.primary as number) ? primaryStyle as AttachmentEstimate['primary'] : null;
    const secondary = primary && secondaryScore >= (thresholds.secondary as number) ? secondaryStyle : null;

    const distance = Math.max(0, (primaryScore as number) - (secondaryScore as number));
    const progress = Math.max(0, Math.min(1, daysObserved / learningDays));
    const confidence = Math.max(0, Math.min(1, 0.25 * distance + 0.75 * progress));

    return {
      primary,
      secondary,
      windowComplete: Boolean(s.windowComplete),
      confidence,
      scores: combined,
      daysObserved: Math.round(daysObserved * 10) / 10, // Round to 1 decimal for consistency
      totalSignals
    };
  }

  addCommunication(text: string, context: string, tone: string): void {
    this.data.communicationHistory.push({
      text,
      context,
      tone,
      timestamp: new Date()
    });

    // Keep only last 50 communications in memory
    if (this.data.communicationHistory.length > 50) {
      this.data.communicationHistory = this.data.communicationHistory.slice(-50);
    }

    // Update learning signals based on tone analysis results
    this.updateLearningSignalsFromTone(tone, context);
    
    // Persist data changes to storage
    this.persistData(text, context, tone);
  }

  private updateLearningSignalsFromTone(tone: string, context: string): void {
    // Map tone to attachment style signals based on patterns
    const toneToAttachmentMapping: Record<string, Partial<{ anxious: number; avoidant: number; secure: number; disorganized: number }>> = {
      'anxious': { anxious: 0.8, secure: 0.1, disorganized: 0.1 },
      'frustrated': { anxious: 0.6, disorganized: 0.3, avoidant: 0.1 },
      'angry': { disorganized: 0.5, anxious: 0.3, avoidant: 0.2 },
      'sad': { anxious: 0.5, disorganized: 0.3, secure: 0.2 },
      'confident': { secure: 0.7, avoidant: 0.2, anxious: 0.1 },
      'supportive': { secure: 0.8, anxious: 0.1, avoidant: 0.1 },
      'positive': { secure: 0.6, anxious: 0.2, avoidant: 0.2 },
      'neutral': { secure: 0.4, anxious: 0.2, avoidant: 0.2, disorganized: 0.2 },
      'assertive': { secure: 0.5, avoidant: 0.3, anxious: 0.2 },
      'tentative': { anxious: 0.6, secure: 0.2, avoidant: 0.2 }
    };

    const mapping = toneToAttachmentMapping[tone] || toneToAttachmentMapping['neutral'];
    
    // Update learning signals with small incremental changes (session-based)
    Object.entries(mapping).forEach(([style, weight]) => {
      const currentValue = Number(this.data.learningSignals[style] || 0);
      this.data.learningSignals[style] = currentValue + (weight * 0.1); // Small incremental learning
    });

    // Simulate accumulated learning over time for demo purposes
    // In real implementation, this would come from the device's stored learning history
    const currentCount = Number(this.data.learningSignals.totalCommunications || 0);
    this.data.learningSignals.totalCommunications = currentCount + 1;
    
    // Simulate days observed based on communication count (for demo)
    // Real implementation would get this from device storage
    this.data.learningSignals.daysObserved = Math.min(
      Math.floor(this.data.learningSignals.totalCommunications / 10), // Rough: 10 communications per day
      7 // Cap at 7 days for learning window
    );
    
    // Mark window complete after sufficient data
    this.data.learningSignals.windowComplete = this.data.learningSignals.daysObserved >= 7;

    logger.info('Updated learning signals from tone analysis', {
      userId: this.userId,
      tone,
      context,
      totalCommunications: this.data.learningSignals.totalCommunications,
      daysObserved: this.data.learningSignals.daysObserved,
      windowComplete: this.data.learningSignals.windowComplete,
      updatedSignals: {
        anxious: this.data.learningSignals.anxious,
        avoidant: this.data.learningSignals.avoidant,
        secure: this.data.learningSignals.secure,
        disorganized: this.data.learningSignals.disorganized
      }
    });
  }

  private persistData(text: string, context: string, tone: string): void {
    // For the keyboard/app sync architecture, we process data and return results
    // The actual persistence happens on the device via SafeKeyboardDataStorage
    logger.info('Communication processed for device sync', {
      userId: this.userId,
      textLength: text.length,
      context,
      tone,
      currentSignals: this.data.learningSignals,
      // Data will be synced back to device for local storage
    });
    
    // Note: In this architecture, the API processes and returns learning progress
    // but the keyboard extension and main app handle the actual data persistence
    // via SafeKeyboardDataStorage.recordToneAnalysis() and similar methods
  }

  private createTextHash(text: string): string {
    // Simple hash for privacy - in production, use crypto
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
      const char = text.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return Math.abs(hash).toString(36);
  }

  getLearningSignals(): Record<string, any> {
    return this.data.learningSignals;
  }

  getPreferences(): ProfileData['preferences'] {
    return this.data.preferences;
  }

  updatePreferences(updates: Partial<ProfileData['preferences']>): void {
    this.data.preferences = { ...this.data.preferences, ...updates };
  }
}