#!/usr/bin/env node

// Test Meta-Classifier Integration
// Verify that meta-classifier results now influence tone bucket mapping

const testCases = [
  // These should now benefit from meta-classifier intelligence
  { text: "I appreciate your help", expected: "clear", reason: "Positive expression should get clear" },
  { text: "That's a good point", expected: "clear", reason: "Supportive language should get clear" },
  { text: "You shut up right now", expected: "caution", reason: "pCaution=0.632 > pAlert=0.609 should map to caution" },
  { text: "With all due respect, that's stupid", expected: "caution", reason: "Belittling construction should be caution, not alert" },
  { text: "You're fucking stupid", expected: "alert", reason: "Direct insult + profanity should remain alert" },
];

const API_BASE = 'https://api.myunsaidapp.com';

console.log('🧠 Testing Meta-Classifier Integration');
console.log('=' .repeat(50));

async function testSentence(text, expected, reason) {
  try {
    console.log(`\n📝 Testing: "${text}"`);
    console.log(`Expected: ${expected} (${reason})`);
    
    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer test-key'
      },
      body: JSON.stringify({ 
        text: text,
        context: 'general',
        attachment_style: 'secure',
        include_explanation: true
      })
    });
    
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    
    const result = await response.json();
    const data = result.data || result;
    
    const actual = data.ui_tone;
    const confidence = data.confidence || 0;
    const distribution = data.ui_distribution || {};
    
    const isCorrect = actual === expected;
    console.log(`Result: ${actual} ${isCorrect ? '✅' : '❌'} (confidence: ${confidence.toFixed(3)})`);
    console.log(`Distribution: Alert=${distribution.alert}, Caution=${distribution.caution}, Clear=${distribution.clear}`);
    
    return { text, expected, actual, correct: isCorrect, distribution };
    
  } catch (error) {
    console.log(`❌ Error: ${error.message}`);
    return { text, expected, actual: 'error', correct: false };
  }
}

async function runTests() {
  console.log('Testing if meta-classifier now influences tone buckets...\n');
  
  const results = [];
  for (let i = 0; i < testCases.length; i++) {
    const { text, expected, reason } = testCases[i];
    const result = await testSentence(text, expected, reason);
    results.push(result);
    
    // Wait between tests to avoid rate limits and clear locks
    if (i < testCases.length - 1) {
      console.log('⏳ Waiting 3s...');
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
  }
  
  // Summary
  console.log('\n' + '=' .repeat(50));
  console.log('📊 META-CLASSIFIER INTEGRATION TEST RESULTS');
  console.log('=' .repeat(50));
  
  const correct = results.filter(r => r.correct).length;
  const total = results.length;
  console.log(`Accuracy: ${correct}/${total} (${((correct/total)*100).toFixed(1)}%)`);
  
  // Show improvements
  const improvements = results.filter(r => r.correct && ['clear', 'caution'].includes(r.expected));
  console.log(`\n✅ Successful nuanced detections: ${improvements.length}`);
  improvements.forEach(imp => {
    console.log(`  "${imp.text}" → ${imp.actual} ✓`);
  });
  
  // Show remaining issues
  const errors = results.filter(r => !r.correct);
  if (errors.length > 0) {
    console.log(`\n❌ Still need work: ${errors.length}`);
    errors.forEach(err => {
      console.log(`  "${err.text}"`);
      console.log(`    Expected: ${err.expected} → Got: ${err.actual}`);
    });
  }
  
  console.log('\n💡 Key: Look for more diverse distributions instead of fixed 0.6/0.3/0.1 pattern');
}

// Check if fetch is available
if (typeof fetch === 'undefined') {
  const fetch = require('node-fetch');
  global.fetch = fetch;
}

runTests().catch(console.error);