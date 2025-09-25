#!/usr/bin/env node

/**
 * Therapy Advice Tone Analysis Script
 * 
 * This script analyzes each therapy_advice.json entry and suggests TWO trigger tones:
 * 1. UI Bucket Tone: alert, caution, or clear (for broad categorization)
 * 2. Specific Raw Tone: one of the 21 tones from evaluation_tones.json (for precise matching)
 * 
 * Usage: node analyze_therapy_advice_tones.js
 */

const fs = require('fs');
const path = require('path');

// Load data files
const therapyAdvice = JSON.parse(fs.readFileSync('./data/therapy_advice.json', 'utf8'));
const evaluationTones = JSON.parse(fs.readFileSync('./data/evaluation_tones.json', 'utf8'));
const toneBucketMapping = JSON.parse(fs.readFileSync('./data/tone_bucket_mapping.json', 'utf8'));

// Available tones
const UI_BUCKET_TONES = ['clear', 'caution', 'alert'];
const RAW_TONES = evaluationTones.rawTones || [
  "neutral","positive","supportive","anxious","angry","frustrated","sad","assertive","safety_concern",
  "withdrawn","apologetic","curious","dismissive","defensive","jealous_insecure","catastrophizing",
  "minimization","playful","reflective","logistical","confused_ambivalent"
];

// Filter out UI bucket tones from raw tones
const SPECIFIC_RAW_TONES = RAW_TONES.filter(tone => !UI_BUCKET_TONES.includes(tone));

console.log('Available UI Bucket Tones:', UI_BUCKET_TONES);
console.log('Available Raw Tones:', SPECIFIC_RAW_TONES);

// Tone classification keywords and patterns
const TONE_PATTERNS = {
  // Positive/Supportive (Clear-leaning)
  positive: [
    /\b(great|wonderful|amazing|excellent|fantastic|love|appreciate|grateful|thank|celebrate|proud|happy|joy)\b/i,
    /\b(positive|good|better|improvement|progress|success|achievement|accomplishment)\b/i,
    /\b(excited|optimistic|hopeful|encouraging|uplifting)\b/i
  ],
  
  supportive: [
    /\b(support|help|assist|care|comfort|understand|empathy|compassion|kindness)\b/i,
    /\b(here for you|you're not alone|we can work through this|I'm listening)\b/i,
    /\b(validate|acknowledge|recognize|see|hear|feel)\b/i,
    /\b(together|partnership|team|collaborate)\b/i
  ],
  
  playful: [
    /\b(fun|playful|joke|laugh|humor|silly|lighthearted|tease)\b/i,
    /\b(game|play|enjoy|entertainment|amusing)\b/i,
    /😊|😄|😂|🎉|😉/
  ],
  
  curious: [
    /\b(wonder|curious|explore|discover|learn|investigate|question|inquiry)\b/i,
    /\b(what if|how about|have you considered|I'm interested in|tell me more)\b/i,
    /\b(explore|dig deeper|understand better|clarify)\b/i
  ],
  
  reflective: [
    /\b(reflect|think|consider|ponder|contemplate|meditate|process)\b/i,
    /\b(insight|awareness|realization|understanding|perspective|wisdom)\b/i,
    /\b(look back|examine|analyze|evaluate)\b/i
  ],
  
  // Confident/Assertive
  assertive: [
    /\b(assert|direct|clear|honest|straightforward|confident|firm|strong)\b/i,
    /\b(boundaries|limit|no|stop|enough|stand up for|speak up)\b/i,
    /\b(I need|I want|I feel|I think|my position is)\b/i
  ],
  
  assertive_controlling: [
    /\b(you need to|you have to|you must|you should|you better|do what I say)\b/i,
    /\b(listen to me|pay attention|follow my|obey|comply|demand|insist|require)\b/i,
    /\b(not negotiable|final decision|end of discussion|because I said so)\b/i,
    /\b(telling you|ordering you|commanding|instructing|directing you to)\b/i
  ],
  
  logistical: [
    /\b(schedule|plan|organize|arrange|coordinate|logistics|time|date)\b/i,
    /\b(task|project|work|job|responsibility|duty|assignment)\b/i,
    /\b(practical|concrete|specific|detailed|systematic)\b/i
  ],
  
  // Neutral/Tentative
  neutral: [
    /\b(okay|fine|alright|maybe|perhaps|possibly|could|might)\b/i,
    /\b(neutral|balanced|moderate|reasonable|fair|even)\b/i,
    /\b(I guess|I suppose|whatever|sure)\b/i
  ],
  
  apologetic: [
    /\b(sorry|apologize|regret|mistake|wrong|fault|blame|guilt)\b/i,
    /\b(I didn't mean to|excuse me|pardon|forgive|my bad)\b/i,
    /\b(shouldn't have|take responsibility|make amends)\b/i
  ],
  
  confused_ambivalent: [
    /\b(confused|unclear|uncertain|mixed feelings|torn|conflicted|ambivalent)\b/i,
    /\b(don't know|not sure|can't decide|difficult choice|both sides)\b/i,
    /\b(contradiction|paradox|dilemma|struggle)\b/i
  ],
  
  // Emotional Distress (Caution-leaning)
  anxious: [
    /\b(anxious|anxiety|worry|worried|nervous|stress|stressed|fear|afraid|scared)\b/i,
    /\b(panic|overwhelm|overthink|catastrophe|disaster|terrible|awful)\b/i,
    /\b(what if|can't handle|too much|breaking point)\b/i
  ],
  
  sad: [
    /\b(sad|sadness|depressed|down|low|blue|grief|mourn|cry|tears)\b/i,
    /\b(hurt|pain|ache|heartbreak|loss|empty|lonely|isolated)\b/i,
    /\b(hopeless|despair|defeated|broken)\b/i
  ],
  
  frustrated: [
    /\b(frustrated|frustration|annoyed|irritated|fed up|sick of|tired of)\b/i,
    /\b(stuck|blocked|can't|won't work|nothing works|tried everything)\b/i,
    /\b(giving up|at my wit's end|had enough)\b/i
  ],
  
  withdrawn: [
    /\b(withdrawn|distant|pull away|shut down|close off|isolate|alone)\b/i,
    /\b(don't want to talk|leave me alone|need space|going quiet)\b/i,
    /\b(retreat|hide|avoid|disconnect|detach)\b/i
  ],
  
  jealous_insecure: [
    /\b(jealous|jealousy|insecure|insecurity|comparison|not good enough)\b/i,
    /\b(threatened|replace|better than me|inadequate|inferior)\b/i,
    /\b(self-doubt|confidence|worth|value|deserve)\b/i
  ],
  
  catastrophizing: [
    /\b(catastrophe|disaster|worst case|everything will|nothing will|always|never)\b/i,
    /\b(end of the world|terrible|horrible|awful|nightmare|ruin)\b/i,
    /\b(what if the worst|blow up|fall apart|collapse)\b/i
  ],
  
  minimization: [
    /\b(not a big deal|no big deal|it's fine|doesn't matter|whatever|minimize)\b/i,
    /\b(not important|trivial|small|insignificant|brush off)\b/i,
    /\b(forget about it|move on|get over it|no need to worry)\b/i
  ],
  
  // Defensive/Negative (Alert-leaning)
  defensive: [
    /\b(defensive|defend|protect|attack|blame|fault|excuse|justify)\b/i,
    /\b(not my fault|you always|you never|I didn't do|why are you)\b/i,
    /\b(turn it around|make it about|twist my words)\b/i
  ],
  
  dismissive: [
    /\b(dismiss|ignore|brush off|wave off|don't care|whatever|so what)\b/i,
    /\b(not listening|don't want to hear|over it|done with this)\b/i,
    /\b(ridiculous|stupid|pointless|waste of time)\b/i
  ],
  
  critical: [
    /\b(critical|criticize|judge|harsh|mean|cruel|attack|tear down)\b/i,
    /\b(wrong|bad|stupid|failure|useless|worthless|pathetic)\b/i,
    /\b(disappointed|let down|expected better|not good enough)\b/i
  ],
  
  // High-Risk (Alert-dominant)
  angry: [
    /\b(angry|anger|mad|furious|rage|pissed|livid|heated|outraged)\b/i,
    /\b(hate|can't stand|sick of|fed up|done|enough|explode)\b/i,
    /\b(you always|you never|this is ridiculous|I'm done)\b/i
  ],
  
  safety_concern: [
    /\b(safety|safe|danger|dangerous|harm|hurt|violence|abuse|threat)\b/i,
    /\b(scared|afraid|fear|terrified|worried about safety)\b/i,
    /\b(protect|escape|help|emergency|crisis|urgent)\b/i
  ]
};

/**
 * Analyze a single therapy advice entry and suggest appropriate dual trigger tones
 */
function analyzeToneForAdvice(advice) {
  const text = `${advice.advice || ''} ${advice.context || ''} ${advice.description || ''}`.toLowerCase();
  
  // Score each raw tone based on pattern matches
  const rawToneScores = {};
  
  for (const [tone, patterns] of Object.entries(TONE_PATTERNS)) {
    if (!SPECIFIC_RAW_TONES.includes(tone)) continue; // Only score specific raw tones
    
    let score = 0;
    for (const pattern of patterns) {
      const matches = text.match(pattern);
      if (matches) {
        score += matches.length;
      }
    }
    if (score > 0) {
      rawToneScores[tone] = score;
    }
  }
  
  // Get attachment style for this advice entry
  const attachmentStyles = advice.attachmentStyles || [];
  const primaryAttachment = attachmentStyles.length > 0 ? attachmentStyles[0] : null;
  
  // Get top raw tone suggestions with attachment-aware UI bucket mapping
  const topRawTones = Object.entries(rawToneScores)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([tone, score]) => ({ 
      tone, 
      score, 
      confidence: Math.min(score * 0.3, 1.0),
      uiBucket: getUIBucketForTone(tone, primaryAttachment),
      attachmentContext: primaryAttachment
    }));
  
  // Determine UI bucket based on content analysis
  const uiBucketSuggestion = determineUIBucket(advice, text, topRawTones, primaryAttachment);
  
  // Add contextual suggestions
  const contextualSuggestions = getContextualSuggestions(advice, text);
  
  return {
    currentTone: advice.triggerTone || 'unknown',
    dualToneSuggestions: {
      uiBucket: uiBucketSuggestion,
      rawTone: topRawTones[0] || null
    },
    topRawTones,
    contextualSuggestions,
    analysis: {
      textLength: text.length,
      hasEmotionalKeywords: /\b(feel|emotion|hurt|pain|love|care|worry|fear|angry|sad|happy)\b/i.test(text),
      hasActionKeywords: /\b(try|practice|consider|think about|work on|focus on)\b/i.test(text),
      hasBoundaryKeywords: /\b(boundary|limit|say no|respect|space|time)\b/i.test(text),
      hasConflictKeywords: /\b(fight|argue|conflict|disagree|tension|problem)\b/i.test(text),
      hasSafetyKeywords: /\b(safe|danger|harm|hurt|threat|violence|abuse|emergency)\b/i.test(text),
      hasIntensityKeywords: /\b(very|extremely|really|so|too|always|never|completely|totally)\b/i.test(text)
    }
  };
}

/**
 * Get UI bucket for a raw tone using tone_bucket_mapping.json with attachment style consideration
 */
function getUIBucketForTone(rawTone, attachmentStyle = null) {
  const mapping = toneBucketMapping.toneBuckets[rawTone];
  if (!mapping || !mapping.base) return 'clear';
  
  let { clear, caution, alert } = mapping.base;
  
  // Apply attachment style overrides if available
  if (attachmentStyle && toneBucketMapping.attachmentOverrides && toneBucketMapping.attachmentOverrides[attachmentStyle]) {
    const overrides = toneBucketMapping.attachmentOverrides[attachmentStyle][rawTone];
    if (overrides) {
      clear += (overrides.clear || 0);
      caution += (overrides.caution || 0);
      alert += (overrides.alert || 0);
      
      // Normalize to ensure they sum to 1
      const sum = clear + caution + alert;
      if (sum > 0) {
        clear /= sum;
        caution /= sum;
        alert /= sum;
      }
    }
  }
  
  // Return the bucket with highest probability
  if (alert >= clear && alert >= caution) return 'alert';
  if (caution >= clear && caution >= alert) return 'caution';
  return 'clear';
}

/**
 * Determine appropriate UI bucket based on content analysis and attachment style
 */
function determineUIBucket(advice, text, topRawTones, attachmentStyle = null) {
  let score = { clear: 0, caution: 0, alert: 0 };
  
  // Get attachment styles from advice if not provided
  const attachmentStyles = advice.attachmentStyles || [];
  const primaryAttachment = attachmentStyle || (attachmentStyles.length > 0 ? attachmentStyles[0] : null);
  
  // Special handling for assertive tone with controlling language
  if (topRawTones.length > 0 && topRawTones[0].tone === 'assertive') {
    const controllingPatterns = TONE_PATTERNS.assertive_controlling;
    let hasControllingLanguage = false;
    
    for (const pattern of controllingPatterns) {
      if (pattern.test(text)) {
        hasControllingLanguage = true;
        score.caution += 4;
        break;
      }
    }
    
    // Check for gentle assertive language
    const gentlePatterns = [
      /\b(I would appreciate|could you please|would you be willing|I'd like to request)\b/i,
      /\b(it would help if|when you|I feel better when|it works better when)\b/i,
      /\b(consider|perhaps|might want to|could try)\b/i
    ];
    
    for (const pattern of gentlePatterns) {
      if (pattern.test(text)) {
        score.clear += 3;
        break;
      }
    }
    
    // Attachment-specific adjustments for assertive
    if (primaryAttachment === 'secure') {
      score.clear += 2; // Secure attachment handles assertive better
    } else if (primaryAttachment === 'avoidant') {
      score.caution += 1; // Avoidant may struggle with assertive advice
    }
  }
  
  // Attachment-specific scoring adjustments
  if (primaryAttachment && topRawTones.length > 0) {
    const topTone = topRawTones[0].tone;
    
    // Avoidant-specific adjustments
    if (primaryAttachment === 'avoidant') {
      if (['withdrawn', 'sad', 'anxious'].includes(topTone)) {
        score.alert += 3; // These are more concerning for avoidant
      }
      if (['apologetic', 'supportive', 'curious'].includes(topTone)) {
        score.clear += 2; // These are safer/clearer for avoidant
      }
    }
    
    // Anxious-specific adjustments  
    if (primaryAttachment === 'anxious') {
      if (['apologetic', 'jealous_insecure', 'catastrophizing'].includes(topTone)) {
        score.caution += 3; // These need caution for anxious
      }
      if (topTone === 'withdrawn') {
        score.caution += 2; // Withdrawn is caution, not alert for anxious
      }
    }
    
    // Disorganized-specific adjustments
    if (primaryAttachment === 'disorganized') {
      if (['angry', 'defensive', 'withdrawn', 'catastrophizing'].includes(topTone)) {
        score.alert += 2; // Higher sensitivity to these tones
      }
    }
  }
  
  // Base scoring from content keywords
  if (/\b(safe|help|support|positive|good|better|healthy|clear|direct)\b/i.test(text)) {
    score.clear += 3;
  }
  
  if (/\b(careful|caution|watch|concern|worry|might|could|consider|think about)\b/i.test(text)) {
    score.caution += 3;
  }
  
  if (/\b(stop|danger|emergency|crisis|urgent|serious|immediately|warning|threat)\b/i.test(text)) {
    score.alert += 5;
  }
  
  // Factor in top raw tone's natural UI bucket (but adjust for assertive)
  if (topRawTones.length > 0) {
    const topTone = topRawTones[0];
    if (topTone.tone === 'assertive') {
      // Already handled above with special logic
    } else {
      score[topTone.uiBucket] += 2;
    }
  }
  
  // Factor in categories
  const categories = advice.categories || [];
  if (categories.includes('safety') || categories.includes('crisis')) {
    score.alert += 4;
  }
  if (categories.includes('conflict_resolution') || categories.includes('emotional_regulation')) {
    score.caution += 2;
  }
  if (categories.includes('positive_communication') || categories.includes('relationship_building')) {
    score.clear += 2;
  }
  
  // Factor in contexts
  const contexts = advice.contexts || [];
  if (contexts.includes('safety') || contexts.includes('escalation')) {
    score.alert += 3;
  }
  if (contexts.includes('conflict') || contexts.includes('repair')) {
    score.caution += 2;
  }
  if (contexts.includes('general') || contexts.includes('planning')) {
    score.clear += 1;
  }
  
  // Return highest scoring bucket
  const maxBucket = Object.entries(score).reduce((max, [bucket, value]) => 
    value > max.value ? { bucket, value } : max, 
    { bucket: 'clear', value: 0 }
  );
  
  return {
    bucket: maxBucket.bucket,
    confidence: Math.min(maxBucket.value / 10, 1.0),
    scores: score
  };
}

/**
 * Get contextual suggestions based on advice content and categories
 */
function getContextualSuggestions(advice, text) {
  const suggestions = [];
  
  // Check categories for raw tone suggestions
  const categories = advice.categories || [];
  if (categories.includes('conflict_resolution')) {
    suggestions.push({ 
      reason: 'conflict_resolution category', 
      uiBucket: 'caution',
      rawTones: ['defensive', 'angry', 'frustrated'] 
    });
  }
  if (categories.includes('emotional_support')) {
    suggestions.push({ 
      reason: 'emotional_support category', 
      uiBucket: 'caution',
      rawTones: ['sad', 'anxious', 'supportive'] 
    });
  }
  if (categories.includes('boundary_setting')) {
    suggestions.push({ 
      reason: 'boundary_setting category', 
      uiBucket: 'clear',
      rawTones: ['assertive', 'defensive'] 
    });
  }
  if (categories.includes('safety') || categories.includes('crisis')) {
    suggestions.push({ 
      reason: 'safety/crisis category', 
      uiBucket: 'alert',
      rawTones: ['safety_concern', 'anxious'] 
    });
  }
  
  // Check contexts
  const contexts = advice.contexts || [];
  if (contexts.includes('conflict')) {
    suggestions.push({ 
      reason: 'conflict context', 
      uiBucket: 'caution',
      rawTones: ['angry', 'frustrated', 'defensive'] 
    });
  }
  if (contexts.includes('repair')) {
    suggestions.push({ 
      reason: 'repair context', 
      uiBucket: 'clear',
      rawTones: ['apologetic', 'supportive', 'sad'] 
    });
  }
  if (contexts.includes('escalation')) {
    suggestions.push({ 
      reason: 'escalation context', 
      uiBucket: 'alert',
      rawTones: ['angry', 'catastrophizing'] 
    });
  }
  if (contexts.includes('safety')) {
    suggestions.push({ 
      reason: 'safety context', 
      uiBucket: 'alert',
      rawTones: ['safety_concern', 'anxious'] 
    });
  }
  
  // Check attachment styles
  const attachmentStyles = advice.attachmentStyles || [];
  if (attachmentStyles.includes('anxious')) {
    suggestions.push({ 
      reason: 'anxious attachment style', 
      uiBucket: 'caution',
      rawTones: ['anxious', 'jealous_insecure', 'catastrophizing'] 
    });
  }
  if (attachmentStyles.includes('avoidant')) {
    suggestions.push({ 
      reason: 'avoidant attachment style', 
      uiBucket: 'caution',
      rawTones: ['withdrawn', 'dismissive', 'defensive'] 
    });
  }
  
  return suggestions;
}

/**
 * Main analysis function
 */
function analyzeAllTherapyAdvice() {
  console.log('🔍 Analyzing therapy advice entries for DUAL trigger tone suggestions...\n');
  console.log(`📊 Total entries to analyze: ${therapyAdvice.length}`);
  console.log(`🎯 UI Bucket Tones: ${UI_BUCKET_TONES.join(', ')}`);
  console.log(`🎯 Raw Tones: ${SPECIFIC_RAW_TONES.join(', ')}\n`);
  
  const results = therapyAdvice.map((advice, index) => {
    const analysis = analyzeToneForAdvice(advice);
    
    if (index < 10) { // Show first 10 for preview
      console.log(`\n--- Entry ${index + 1} ---`);
      console.log(`Current: ${analysis.currentTone}`);
      console.log(`Text: "${(advice.advice || '').substring(0, 100)}..."`);

      const dualSuggestion = analysis.dualToneSuggestions;
      console.log(`🎯 DUAL TONE SUGGESTION:`);
      console.log(`   UI Bucket: ${dualSuggestion.uiBucket.bucket} (confidence: ${dualSuggestion.uiBucket.confidence.toFixed(2)})`);
      console.log(`   Raw Tone: ${dualSuggestion.rawTone ? dualSuggestion.rawTone.tone : 'none'} (score: ${dualSuggestion.rawTone ? dualSuggestion.rawTone.score : 0})`);
      
      if (analysis.contextualSuggestions.length > 0) {
        console.log(`📝 Context suggests:`, analysis.contextualSuggestions.map(s => `${s.uiBucket}+${s.rawTones[0]}`).join(', '));
      }
    }
    
    return {
      id: advice.id,
      currentTone: analysis.currentTone,
      suggestedUIBucket: analysis.dualToneSuggestions.uiBucket.bucket,
      suggestedRawTone: analysis.dualToneSuggestions.rawTone ? analysis.dualToneSuggestions.rawTone.tone : null,
      confidence: {
        uiBucket: analysis.dualToneSuggestions.uiBucket.confidence,
        rawTone: analysis.dualToneSuggestions.rawTone ? analysis.dualToneSuggestions.rawTone.confidence : 0
      },
      ...analysis
    };
  });
  
  // Generate statistics
  const stats = generateStatistics(results);
  console.log('\n📈 Analysis Statistics:');
  console.log(`- Entries with no current tone: ${stats.noCurrentTone}`);
  console.log(`- Entries with dual suggestions: ${stats.withDualSuggestions}`);
  console.log(`- Most suggested UI buckets:`, Object.entries(stats.topUIBuckets).slice(0, 3));
  console.log(`- Most suggested raw tones:`, Object.entries(stats.topRawTones).slice(0, 5));
  
  // Save results
  const outputPath = './therapy_advice_dual_tone_analysis.json';
  fs.writeFileSync(outputPath, JSON.stringify({
    timestamp: new Date().toISOString(),
    totalEntries: therapyAdvice.length,
    availableUIBuckets: UI_BUCKET_TONES,
    availableRawTones: SPECIFIC_RAW_TONES,
    statistics: stats,
    results: results.slice(0, 50) // Save first 50 for review, full results would be too large
  }, null, 2));
  
  // Save a CSV for easier review
  const csvPath = './therapy_advice_dual_tone_suggestions.csv';
  const csvContent = [
    'ID,Current Tone,Suggested UI Bucket,UI Confidence,Suggested Raw Tone,Raw Confidence,Text Preview',
    ...results.slice(0, 100).map(r => 
      `"${r.id}","${r.currentTone}","${r.suggestedUIBucket}","${r.confidence.uiBucket.toFixed(2)}","${r.suggestedRawTone || 'none'}","${r.confidence.rawTone.toFixed(2)}","${(therapyAdvice.find(a => a.id === r.id)?.advice || '').replace(/"/g, '""').substring(0, 100)}"`
    )
  ].join('\n');
  
  fs.writeFileSync(csvPath, csvContent);
  
  console.log(`\n💾 Analysis saved to: ${outputPath}`);
  console.log(`📊 CSV for review saved to: ${csvPath}`);
  console.log('\n✨ Next steps:');
  console.log('1. Review the CSV file for easy browsing of suggestions');
  console.log('2. Update therapy_advice.json entries with dual trigger tones:');
  console.log('   - "triggerTone": ["clear", "supportive"] (UI bucket + raw tone)');
  console.log('   - OR "triggerTone": "clear", "rawTone": "supportive" (separate fields)');
  console.log('3. Focus on high-confidence suggestions first');
  console.log('4. Update the tone matching logic to handle dual tones');
}

/**
 * Generate analysis statistics
 */
function generateStatistics(results) {
  const stats = {
    noCurrentTone: 0,
    withDualSuggestions: 0,
    topUIBuckets: {},
    topRawTones: {},
    currentToneDistribution: {},
    confidenceDistribution: { high: 0, medium: 0, low: 0 }
  };
  
  results.forEach(result => {
    // Count entries without current tone
    if (!result.currentTone || result.currentTone === 'unknown') {
      stats.noCurrentTone++;
    }
    
    // Count current tone distribution
    const currentTone = result.currentTone || 'unknown';
    stats.currentToneDistribution[currentTone] = (stats.currentToneDistribution[currentTone] || 0) + 1;
    
    // Count dual suggestions
    if (result.suggestedUIBucket && result.suggestedRawTone) {
      stats.withDualSuggestions++;
    }
    
    // Count UI bucket suggestions
    if (result.suggestedUIBucket) {
      stats.topUIBuckets[result.suggestedUIBucket] = (stats.topUIBuckets[result.suggestedUIBucket] || 0) + 1;
    }
    
    // Count raw tone suggestions
    if (result.suggestedRawTone) {
      stats.topRawTones[result.suggestedRawTone] = (stats.topRawTones[result.suggestedRawTone] || 0) + 1;
    }
    
    // Count confidence distribution
    const avgConfidence = (result.confidence.uiBucket + result.confidence.rawTone) / 2;
    if (avgConfidence >= 0.7) {
      stats.confidenceDistribution.high++;
    } else if (avgConfidence >= 0.4) {
      stats.confidenceDistribution.medium++;
    } else {
      stats.confidenceDistribution.low++;
    }
  });
  
  // Sort suggestions by frequency
  stats.topUIBuckets = Object.entries(stats.topUIBuckets)
    .sort((a, b) => b[1] - a[1])
    .reduce((obj, [bucket, count]) => {
      obj[bucket] = count;
      return obj;
    }, {});
  
  stats.topRawTones = Object.entries(stats.topRawTones)
    .sort((a, b) => b[1] - a[1])
    .reduce((obj, [tone, count]) => {
      obj[tone] = count;
      return obj;
    }, {});
  
  return stats;
}

// Run the analysis
if (require.main === module) {
  analyzeAllTherapyAdvice();
}

module.exports = { analyzeToneForAdvice, analyzeAllTherapyAdvice };