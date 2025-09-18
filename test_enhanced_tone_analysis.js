#!/usr/bin/env node

// Test Enhanced Tone Analysis with Human-like Detection
// Tests all the new capabilities: meta-classifier, advanced detection, conversation awareness

const { execSync } = require('child_process');
const fs = require('fs');

// Test sentences covering different detection categories
const testCases = [
  // === Basic Profanity & Targeting ===
  { text: "You're fucking stupid", expected: "alert", category: "Strong Profanity + Targeting" },
  { text: "That's fucking annoying", expected: "caution", category: "Strong Profanity (non-targeted)" },
  { text: "F*ck this sh*t", expected: "caution", category: "Masked Profanity" },
  { text: "You're f'ing ridiculous", expected: "alert", category: "Masked Profanity + Targeting" },
  
  // === Targeted Imperatives ===
  { text: "You shut up right now", expected: "alert", category: "Targeted Imperative" },
  { text: "You need to stop this", expected: "caution", category: "Soft Imperative" },
  { text: "Just listen to me", expected: "caution", category: "General Imperative" },
  { text: "You go away", expected: "alert", category: "Targeted Imperative" },
  
  // === Threat Intent ===
  { text: "I'll make you regret this", expected: "alert", category: "Threat Intent" },
  { text: "I'm gonna report you", expected: "alert", category: "Threat Intent" },
  { text: "Do that or else", expected: "alert", category: "Threat Intent" },
  { text: "I will destroy your reputation", expected: "alert", category: "Threat Intent" },
  
  // === Belittling Constructions ===
  { text: "No offense, but you're an idiot", expected: "alert", category: "Belittling + Insult" },
  { text: "With all due respect, that's stupid", expected: "caution", category: "Belittling Construction" },
  { text: "Calm down, you're overreacting", expected: "caution", category: "Dismissive Command" },
  { text: "Just saying, you're wrong", expected: "caution", category: "Passive Belittling" },
  
  // === Advanced Sarcasm ===
  { text: "Great job, genius 🙂", expected: "caution", category: "Sarcastic Praise + Fake Softener" },
  { text: "You're not stupid, but clearly you don't get it", expected: "caution", category: "Backhanded Compliment" },
  { text: "Perfect work as usual 🙂", expected: "caution", category: "Sarcasm with Emoji" },
  
  // === Rhetorical Question Heat ===
  { text: "Why are you so incompetent??", expected: "alert", category: "Hostile Question + Heat" },
  { text: "Why do you always do this?!", expected: "caution", category: "Rhetorical Question" },
  { text: "What is wrong with you???", expected: "alert", category: "Multiple Question Marks" },
  
  // === Dismissive Markers ===
  { text: "Whatever, you never listen", expected: "caution", category: "Dismissive Language" },
  { text: "Obviously you don't understand", expected: "caution", category: "Dismissive Adverb" },
  { text: "As usual, you're late", expected: "caution", category: "Dismissive Pattern" },
  
  // === Prosody Signals ===
  { text: "You always do this...", expected: "caution", category: "Ellipses + Targeting" },
  { text: "Reallllly interesting point", expected: "caution", category: "Word Stretching" },
  { text: "What?! Are you serious?!", expected: "caution", category: "Interrobang Pattern" },
  
  // === Emoji Escalation ===
  { text: "You're an idiot 😡", expected: "alert", category: "Anger Emoji + Insult" },
  { text: "Thanks for nothing 🖕", expected: "alert", category: "Middle Finger Emoji" },
  { text: "You're so helpful 🙂", expected: "caution", category: "Fake Softener Sarcasm" },
  
  // === Meta-Classifier Edge Cases ===
  { text: "You constantly make these mistakes", expected: "caution", category: "Absolutes + Targeting" },
  { text: "This is literally the worst", expected: "caution", category: "Hyperbolic Language" },
  { text: "You NEVER listen to anyone", expected: "caution", category: "Caps + Absolutes" },
  
  // === Clear/Positive Cases ===
  { text: "I appreciate your help", expected: "clear", category: "Positive Expression" },
  { text: "That's a good point", expected: "clear", category: "Supportive" },
  { text: "Let me think about that", expected: "clear", category: "Neutral/Thoughtful" },
  { text: "I understand your perspective", expected: "clear", category: "Empathetic" },
  
  // === Complex Mixed Cases ===
  { text: "Look, I'm not trying to be mean, but you're really struggling here", expected: "caution", category: "Softener + Criticism" },
  { text: "I love how you always find a way to mess this up 🙂", expected: "alert", category: "Sarcasm + Pattern + Emoji" },
  { text: "You know what? Fine. Do whatever you want.", expected: "caution", category: "Resignation + Dismissiveness" },
];

// API endpoint
const API_BASE = process.env.UNSAID_API_BASE_URL || 'https://api.myunsaidapp.com';

console.log('🧠 Testing Enhanced Tone Analysis System');
console.log('=' .repeat(60));

let results = [];
let totalTests = testCases.length;
let correctPredictions = 0;

async function testToneAnalysis(text) {
  try {
    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.UNSAID_API_KEY || 'test-key'}`
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
  console.log(`Running ${totalTests} test cases...\n`);
  
  for (let i = 0; i < testCases.length; i++) {
    const { text, expected, category } = testCases[i];
    
    console.log(`\n📝 Test ${i + 1}/${totalTests}: ${category}`);
    console.log(`Text: "${text}"`);
    console.log(`Expected: ${expected}`);
    
    const result = await testToneAnalysis(text);
    
    if (result) {
      const actualTone = result.ui_tone || result.primary_tone || 'unknown';
      const confidence = result.confidence || 'N/A';
      const explanation = result.explanation || [];
      const metaClassifier = result.meta_classifier || {};
      
      const isCorrect = actualTone === expected;
      correctPredictions += isCorrect ? 1 : 0;
      
      console.log(`Actual: ${actualTone} ${isCorrect ? '✅' : '❌'}`);
      console.log(`Confidence: ${confidence}`);
      
      if (explanation.length > 0) {
        console.log(`Triggers: ${explanation.join(', ')}`);
      }
      
      if (metaClassifier.pAlert || metaClassifier.pCaution) {
        console.log(`Meta: pAlert=${(metaClassifier.pAlert || 0).toFixed(3)}, pCaution=${(metaClassifier.pCaution || 0).toFixed(3)}`);
      }
      
      results.push({
        text,
        category,
        expected,
        actual: actualTone,
        correct: isCorrect,
        confidence,
        explanation,
        metaClassifier
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
    
    // Longer pause between requests to respect rate limits (20 per minute)
    await new Promise(resolve => setTimeout(resolve, 3500));
  }
  
  // Summary
  console.log('\n' + '=' .repeat(60));
  console.log('📊 TEST RESULTS SUMMARY');
  console.log('=' .repeat(60));
  console.log(`Total Tests: ${totalTests}`);
  console.log(`Correct Predictions: ${correctPredictions}`);
  console.log(`Accuracy: ${((correctPredictions / totalTests) * 100).toFixed(1)}%`);
  
  // Category breakdown
  const categoryStats = {};
  results.forEach(r => {
    if (!categoryStats[r.category]) {
      categoryStats[r.category] = { total: 0, correct: 0 };
    }
    categoryStats[r.category].total++;
    if (r.correct) categoryStats[r.category].correct++;
  });
  
  console.log('\n📈 Accuracy by Category:');
  Object.entries(categoryStats).forEach(([category, stats]) => {
    const accuracy = ((stats.correct / stats.total) * 100).toFixed(1);
    console.log(`  ${category}: ${stats.correct}/${stats.total} (${accuracy}%)`);
  });
  
  // Show misclassifications
  const errors = results.filter(r => !r.correct);
  if (errors.length > 0) {
    console.log('\n❌ Misclassifications:');
    errors.forEach(error => {
      console.log(`  "${error.text}"`);
      console.log(`    Expected: ${error.expected}, Got: ${error.actual}`);
    });
  }
  
  // Save detailed results
  fs.writeFileSync('tone_analysis_test_results.json', JSON.stringify(results, null, 2));
  console.log('\n💾 Detailed results saved to: tone_analysis_test_results.json');
}

// Check if fetch is available (Node 18+) or use node-fetch
if (typeof fetch === 'undefined') {
  console.log('⚠️  Using node-fetch for HTTP requests...');
  const fetch = require('node-fetch');
  global.fetch = fetch;
}

// Run the tests
runTests().catch(console.error);