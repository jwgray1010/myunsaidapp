// api/_lib/services/p-taxonomy.ts
// P-code taxonomy and rule seeds for spaCy link classification

export type PCode = 'P031' | 'P044' | 'P061' | 'P099' | 'P122' | 'P170' | 'P217' | 'P981';

export interface PCodeInfo {
  description: string;
  category: 'communication' | 'boundaries' | 'validation' | 'safety' | 'planning' | 'repair' | 'context';
  keywords: string[];
  patterns: RegExp[];
}

export const P_MAP: Record<PCode, string> = {
  P031: "thread_management_brevity",
  P044: "clarity_assumption_checks", 
  P061: "boundaries_concrete_asks",
  P099: "validation_reflective_listening",
  P122: "safety_intensity_control",
  P170: "expectations_planning",
  P217: "repair_recognition",
  P981: "context_classifier_lane_labeling",
} as const;

export const ALL_P: PCode[] = Object.keys(P_MAP) as PCode[];

// Light, extensible rule seeds (lowercase)
export const RULE_SEEDS: Record<PCode, string[]> = {
  P031: ["tldr", "one topic", "parking lot", "lane", "shorten", "stacked texts"],
  P044: ["assumption", "headline", "clarify", "what did you mean", "specific example"],
  P061: ["boundary", "limit", "capacity", "not available", "one request"],
  P099: ["i hear", "makes sense", "that sounds", "pressure", "uncertainty"],
  P122: ["cool down", "pause", "revisit", "window", "intensity", "overwhelm"],
  P170: ["check-in", "time box", "by when", "cadence", "ritual", "update time"],
  P217: ["i own my part", "appreciate", "thanks for", "shared goal"],
  P981: ["scope", "lane", "process map", "steps", "status first"],
};

// Human-readable descriptions for debugging/UI
export const P_DESCRIPTIONS: Record<PCode, string> = {
  P031: "Thread management and brevity - keeping conversations focused and concise",
  P044: "Clarity and assumption checks - verifying understanding and meaning",
  P061: "Boundaries and concrete asks - setting limits and making specific requests", 
  P099: "Validation and reflective listening - acknowledging and reflecting back",
  P122: "Safety and intensity control - managing emotional overwhelm and creating space",
  P170: "Expectations and planning - setting timelines, check-ins, and structures",
  P217: "Repair and recognition - taking responsibility and appreciating efforts",
  P981: "Context classification and lane labeling - organizing conversation scope",
};

// Enhanced pattern definitions for more accurate matching
export const P_PATTERNS: Record<PCode, RegExp[]> = {
  P031: [
    /\b(tldr|tl;dr)\b/i,
    /\b(one topic|single topic)\b/i,
    /\b(parking lot)\b/i,
    /\b(too long|brevity|shorten)\b/i,
    /\b(stacked texts?)\b/i,
    /\b(thread management|manage thread)\b/i,
  ],
  P044: [
    /\b(assumption|assume)\b/i,
    /\b(what did you mean|clarify|clarification)\b/i,
    /\b(headline|summary)\b/i,
    /\b(specific example)\b/i,
    /\b(help me understand)\b/i,
    /\b(assumption check)\b/i,
  ],
  P061: [
    /\b(boundary|boundaries)\b/i,
    /\b(limit|capacity)\b/i,
    /\b(not available|can't do)\b/i,
    /\b(one request|single ask)\b/i,
    /\b(too much|overwhelm)\b/i,
    /\b(concrete ask)\b/i,
  ],
  P099: [
    /\b(i hear|sounds like)\b/i,
    /\b(makes sense)\b/i,
    /\b(that sounds?)\b/i,
    /\b(pressure|stress)\b/i,
    /\b(uncertainty|unclear)\b/i,
    /\b(reflective listening)\b/i,
  ],
  P122: [
    /\b(cool down|pause)\b/i,
    /\b(revisit|come back)\b/i,
    /\b(window|time)\b/i,
    /\b(intensity|intense)\b/i,
    /\b(overwhelm|too much)\b/i,
    /\b(safety|control)\b/i,
  ],
  P170: [
    /\b(check.?in)\b/i,
    /\b(time.?box)\b/i,
    /\b(by when|deadline)\b/i,
    /\b(cadence|rhythm)\b/i,
    /\b(ritual|routine)\b/i,
    /\b(update time|planning)\b/i,
  ],
  P217: [
    /\b(i own|my part)\b/i,
    /\b(appreciate|thanks for)\b/i,
    /\b(shared goal)\b/i,
    /\b(sorry|apologize)\b/i,
    /\b(recognize|acknowledge)\b/i,
    /\b(repair|recognition)\b/i,
  ],
  P981: [
    /\b(scope|boundary)\b/i,
    /\b(lane|track)\b/i,
    /\b(process map|workflow)\b/i,
    /\b(steps|phases)\b/i,
    /\b(status first)\b/i,
    /\b(context|classify)\b/i,
  ],
};