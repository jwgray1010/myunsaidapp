// api/_lib/types/featureSpotter.ts
export type FSConfig = {
  version: string;
  globals: { 
    flags: string; 
    maxInputChars: number; 
    timeoutMs: number; 
    dedupeWindowMs: number; 
    matchLimitPerFeature: number; 
  };
  scoringDefaults: {
    baseWeight: number;
    positionBoost: { 
      start: number; 
      end: number; 
      caps: number; 
      repeat: number; 
    };
    cooccurrenceBoost: { 
      withNegation: number; 
      withSarcasm: number; 
      withEmoji: number; 
    };
  };
  features: Array<{ 
    id: string; 
    description: string; 
    patterns: string[]; 
    buckets: string[]; 
    weights?: Record<string, number>; 
    attachmentHints?: Record<string, number>; 
  }>;
  noticingsMap: Record<string, string>;
  aggregation: { 
    decayDays: number; 
    capPerDay: number; 
    noiseFloor: number; 
    cooldownMsPerBucket: Record<string, number>; 
  };
  runtime: { 
    safeOrder: string[]; 
    conflictResolution: { 
      mergeSameBucket: boolean; 
      preferPositiveWhenTied: boolean; 
      maxNoticingsPerMessage: number; 
    }; 
  };
};

export type FSMatch = { 
  featureId: string; 
  bucket: string; 
  matches: string[]; 
  weight: number; 
};

export type FSRunResult = {
  noticings: Array<{ bucket: string; message: string }>;
  matches: FSMatch[];
  intensityHints: number; // 0..1
  attachmentHints: Record<string, number>; // per style
  toneHints: Record<'clear'|'caution'|'alert', number>;
};