#!/usr/bin/env node

// Test complete tone analysis flow
const http = require('http');

const testPayload = {
  text: "I'm really frustrated with this situation and need better advice",
  userId: "test_user",
  context: "general",
  toneAnalysis: {
    // Complete analysis data as coordinator would send it
    tone: "frustrated",
    classification: "frustrated", 
    confidence: 0.85,
    ui_tone: "caution",
    ui_distribution: { clear: 0.1, caution: 0.7, alert: 0.2 },
    emotions: { frustrated: 0.8, anxious: 0.3, hopeful: 0.1 },
    intensity: 0.75,
    sentiment_score: 0.3,
    linguistic_features: {
      formality_level: 0.5,
      emotional_complexity: 0.7,
      assertiveness: 0.6
    },
    context_analysis: {
      appropriateness_score: 0.8,
      relationship_impact: "neutral"
    },
    attachment_insights: ["needs reassurance", "seeking validation"],
    metadata: {
      analysis_depth: 0.75,
      model_version: "v1.0.0-advanced"
    }
  }
};

const options = {
  hostname: 'localhost',
  port: 3000,
  path: '/api/v1/suggestions',
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'x-user-id': 'test_user'
  }
};

const req = http.request(options, (res) => {
  console.log(`🎯 Response Status: ${res.statusCode}`);
  console.log(`🎯 Response Headers:`, res.headers);
  
  let data = '';
  res.on('data', (chunk) => {
    data += chunk;
  });
  
  res.on('end', () => {
    try {
      const response = JSON.parse(data);
      console.log('🎯 SUCCESS: Complete analysis processed!');
      console.log('📝 Suggestion:', response.suggestion?.text?.substring(0, 100) + '...');
      console.log('📊 Used coordinator cache:', response.meta?.usedCache || 'unknown');
      console.log('🧠 Tone analysis source:', response.meta?.toneSource || 'unknown');
    } catch (e) {
      console.log('🎯 Raw response:', data);
    }
  });
});

req.on('error', (e) => {
  console.error(`🔴 Request error: ${e.message}`);
});

req.write(JSON.stringify(testPayload));
req.end();

console.log('🎯 Testing complete tone analysis flow...');
console.log('📊 Payload includes:', Object.keys(testPayload.toneAnalysis).join(', '));