#!/usr/bin/env node

// Tone Analysis Test - Respecting Provisional Lock Timing
// Tests with 2+ second delays to avoid lock interference

const testCases = [
  // Test clear cases first to establish baseline
  { text: "I appreciate your help", expected: "clear", category: "Positive Expression" },
  { text: "That's a good point", expected: "clear", category: "Supportive" },
  { text: "Let me think about that", expected: "clear", category: "Neutral/Thoughtful" },
  
  // Then caution cases
  { text: "That's fucking annoying", expected: "caution", category: "Strong Profanity (non-targeted)" },
  { text: "With all due respect, that's stupid", expected: "caution", category: "Belittling Construction" },
  { text: "Whatever, you never listen", expected: "caution", category: "Dismissive Language" },
  
  // Finally alert cases
  { text: "You're fucking stupid", expected: "alert", category: "Strong Profanity + Targeting" },
  { text: "I'll make you regret this", expected: "alert", category: "Threat Intent" },
  { text: "You shut up right now", expected: "alert", category: "Targeted Imperative" },
];

// API endpoint
const API_BASE = 'https://api.myunsaidapp.com';

console.log('🧠 Tone Analysis Test - Lock-Aware Testing');
console.log('🔒 Respecting 1.2s provisional lock mechanism');
console.log('=' .repeat(55));

let results = [];
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
    return result.data || result;
  } catch (error) {
    console.error(`❌ API Error: ${error.message}`);
    return null;
  }
}

async function runTests() {
  console.log(`Running ${testCases.length} tests with 2s delays...\n`);
  
  for (let i = 0; i < testCases.length; i++) {
    const { text, expected, category } = testCases[i];
    
    console.log(`\n📝 Test ${i + 1}/${testCases.length}: ${category}`);
    console.log(`Text: "${text}"`);
    console.log(`Expected: ${expected}`);
    
    const result = await testToneAnalysis(text);
    
    if (result) {
      const actualTone = result.ui_tone || 'unknown';
      const confidence = result.confidence || 0;
      const isCorrect = actualTone === expected;
      correctPredictions += isCorrect ? 1 : 0;
      
      console.log(`Actual: ${actualTone} ${isCorrect ? '✅' : '❌'} (conf: ${confidence.toFixed(3)})`);
      
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
        confidence
      });
    } else {
      console.log(`❌ Failed to get result`);
    }
    
    // Wait 2+ seconds to clear any provisional locks
    if (i < testCases.length - 1) {
      console.log('⏳ Waiting 2.5s to clear provisional locks...');
      await new Promise(resolve => setTimeout(resolve, 2500));
    }
  }
  
  // Summary
  console.log('\n' + '=' .repeat(55));
  console.log('📊 LOCK-AWARE TEST RESULTS');
  console.log('=' .repeat(55));
  console.log(`Total Tests: ${testCases.length}`);
  console.log(`Correct Predictions: ${correctPredictions}`);
  console.log(`Accuracy: ${((correctPredictions / testCases.length) * 100).toFixed(1)}%`);
  
  // Show results by expected tone
  ['clear', 'caution', 'alert'].forEach(expectedTone => {
    const filtered = results.filter(r => r.expected === expectedTone);
    const correct = filtered.filter(r => r.correct).length;
    console.log(`  ${expectedTone.toUpperCase()}: ${correct}/${filtered.length} (${filtered.length > 0 ? ((correct/filtered.length)*100).toFixed(1) : 0}%)`);
  });
  
  // Show any misclassifications
  const errors = results.filter(r => !r.correct);
  if (errors.length > 0) {
    console.log('\n❌ Misclassifications:');
    errors.forEach(error => {
      console.log(`  "${error.text}"`);
      console.log(`    Expected: ${error.expected} → Got: ${error.actual}`);
    });
  }
  
  console.log('\n💡 Note: Production system uses 1.2s provisional locks for streaming stability');
  console.log('   This prevents tone flicker during real-time keyboard typing.');
}

// Check if fetch is available
if (typeof fetch === 'undefined') {
  const fetch = require('node-fetch');
  global.fetch = fetch;
}

runTests().catch(console.error);