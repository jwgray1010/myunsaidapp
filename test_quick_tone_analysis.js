#!/usr/bin/env node

// Quick Tone Analysis Test - Representative Cases
// Tests key capabilities without hitting rate limits

const { execSync } = require('child_process');

// Representative test cases covering main detection types
const testCases = [
  // === Strong Alert Cases ===
  { text: "You're fucking stupid", expected: "alert", category: "Strong Profanity + Targeting" },
  { text: "I'll make you regret this", expected: "alert", category: "Threat Intent" },
  { text: "You shut up right now", expected: "alert", category: "Targeted Imperative" },
  { text: "Why are you so incompetent??", expected: "alert", category: "Hostile Question + Heat" },
  { text: "You're an idiot 😡", expected: "alert", category: "Anger Emoji + Insult" },
  
  // === Caution Cases ===
  { text: "That's fucking annoying", expected: "caution", category: "Strong Profanity (non-targeted)" },
  { text: "With all due respect, that's stupid", expected: "caution", category: "Belittling Construction" },
  { text: "Great job, genius 🙂", expected: "caution", category: "Sarcastic Praise + Fake Softener" },
  { text: "Whatever, you never listen", expected: "caution", category: "Dismissive Language" },
  { text: "You constantly make these mistakes", expected: "caution", category: "Absolutes + Targeting" },
  
  // === Clear Cases ===
  { text: "I appreciate your help", expected: "clear", category: "Positive Expression" },
  { text: "That's a good point", expected: "clear", category: "Supportive" },
  { text: "Let me think about that", expected: "clear", category: "Neutral/Thoughtful" },
  
  // === Edge Cases ===
  { text: "F*ck this sh*t", expected: "caution", category: "Masked Profanity" },
  { text: "You're not stupid, but clearly you don't get it", expected: "caution", category: "Backhanded Compliment" },
];

// API endpoint
const API_BASE = 'https://api.myunsaidapp.com';

console.log('🧠 Quick Tone Analysis Test - Enhanced System');
console.log('=' .repeat(50));

let results = [];
let totalTests = testCases.length;
let correctPredictions = 0;

async function testToneAnalysis(text) {
  try {
    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer test-key`
      },
      body: JSON.stringify({ 
        text: text,
        context: 'general',
        attachment_style: 'secure',
        include_explanation: true
      })
    });
    
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    
    const result = await response.json();
    return result.data || result; // Handle nested response structure
  } catch (error) {
    console.error(`❌ API Error for "${text}": ${error.message}`);
    return null;
  }
}

async function runTests() {
  console.log(`Running ${totalTests} representative test cases...\n`);
  
  for (let i = 0; i < testCases.length; i++) {
    const { text, expected, category } = testCases[i];
    
    console.log(`\n📝 Test ${i + 1}/${totalTests}: ${category}`);
    console.log(`Text: "${text}"`);
    console.log(`Expected: ${expected}`);
    
    const result = await testToneAnalysis(text);
    
    if (result) {
      const actualTone = result.ui_tone || result.primary_tone || 'unknown';
      const confidence = result.confidence || 'N/A';
      const explanation = result.explanation || result.metadata?.feature_noticings || [];
      const metaClassifier = result.meta_classifier || {};
      const analysis = result.analysis || {};
      
      const isCorrect = actualTone === expected;
      correctPredictions += isCorrect ? 1 : 0;
      
      console.log(`Actual: ${actualTone} ${isCorrect ? '✅' : '❌'} (${typeof confidence === 'number' ? confidence.toFixed(3) : confidence})`);
      
      if (analysis.primary_tone) {
        console.log(`Primary Tone: ${analysis.primary_tone}`);
      }
      
      if (explanation.length > 0) {
        console.log(`Triggers: ${explanation.join(', ')}`);
      }
      
      if (metaClassifier.pAlert || metaClassifier.pCaution) {
        console.log(`Meta: pAlert=${(metaClassifier.pAlert || 0).toFixed(3)}, pCaution=${(metaClassifier.pCaution || 0).toFixed(3)}`);
      }
      
      // Show key detection details
      if (result.ui_distribution) {
        const dist = result.ui_distribution;
        console.log(`Distribution: Alert=${dist.alert}, Caution=${dist.caution}, Clear=${dist.clear}`);
      }
      
      results.push({
        text,
        category,
        expected,
        actual: actualTone,
        correct: isCorrect,
        confidence,
        explanation,
        metaClassifier,
        analysis
      });
    } else {
      console.log(`❌ Failed to get result`);
      results.push({
        text,
        category,
        expected,
        actual: 'error',
        correct: false
      });
    }
    
    // Rate limit friendly pause
    if (i < testCases.length - 1) {
      console.log('⏳ Waiting 4s for rate limit...');
      await new Promise(resolve => setTimeout(resolve, 4000));
    }
  }
  
  // Summary
  console.log('\n' + '=' .repeat(50));
  console.log('📊 QUICK TEST RESULTS');
  console.log('=' .repeat(50));
  console.log(`Total Tests: ${totalTests}`);
  console.log(`Correct Predictions: ${correctPredictions}`);
  console.log(`Accuracy: ${((correctPredictions / totalTests) * 100).toFixed(1)}%`);
  
  // Category breakdown
  const alertTests = results.filter(r => r.expected === 'alert');
  const cautionTests = results.filter(r => r.expected === 'caution');
  const clearTests = results.filter(r => r.expected === 'clear');
  
  console.log('\n📈 Accuracy by Expected Tone:');
  console.log(`  Alert: ${alertTests.filter(r => r.correct).length}/${alertTests.length} (${((alertTests.filter(r => r.correct).length / alertTests.length) * 100).toFixed(1)}%)`);
  console.log(`  Caution: ${cautionTests.filter(r => r.correct).length}/${cautionTests.length} (${((cautionTests.filter(r => r.correct).length / cautionTests.length) * 100).toFixed(1)}%)`);
  console.log(`  Clear: ${clearTests.filter(r => r.correct).length}/${clearTests.length} (${((clearTests.filter(r => r.correct).length / clearTests.length) * 100).toFixed(1)}%)`);
  
  // Show misclassifications
  const errors = results.filter(r => !r.correct && r.actual !== 'error');
  if (errors.length > 0) {
    console.log('\n❌ Misclassifications:');
    errors.forEach(error => {
      console.log(`  "${error.text}"`);
      console.log(`    Expected: ${error.expected} → Got: ${error.actual}`);
      if (error.analysis?.primary_tone) {
        console.log(`    Primary Tone: ${error.analysis.primary_tone}`);
      }
    });
  }
  
  // Show successful detections
  const successes = results.filter(r => r.correct);
  if (successes.length > 0) {
    console.log('\n✅ Successful Detections:');
    successes.forEach(success => {
      console.log(`  "${success.text}" → ${success.actual} ✓`);
    });
  }
}

// Check if fetch is available (Node 18+) or use node-fetch
if (typeof fetch === 'undefined') {
  const fetch = require('node-fetch');
  global.fetch = fetch;
}

// Run the tests
runTests().catch(console.error);