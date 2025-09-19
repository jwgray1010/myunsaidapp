#!/usr/bin/env node

/**
 * Quick test suite for pure base tone classifications
 * Focused on key edge cases and problem areas
 */

const API_BASE = 'https://api.myunsaidapp.com/api/v1/tone';

// Focused test set - most important cases
const focusedTests = [
  // Clearly positive - should be CLEAR
  { text: "this is amazing", expect: "clear", category: "positive" },
  { text: "you did such a great job", expect: "clear", category: "positive" },
  { text: "I really appreciate you", expect: "clear", category: "positive" },
  
  // Passive-aggressive - should be CAUTION  
  { text: "I'm fine", expect: "caution", category: "passive_aggressive" },
  { text: "whatever", expect: "caution", category: "passive_aggressive" },
  { text: "that's just great", expect: "caution", category: "sarcasm" },
  
  // Hostile - should be ALERT
  { text: "you're such an idiot", expect: "alert", category: "hostile" },
  { text: "I hate you", expect: "alert", category: "hostile" },
  { text: "shut up", expect: "alert", category: "hostile" },
  
  // Neutral - should be NEUTRAL/CLEAR
  { text: "the meeting is at 3pm", expect: "neutral", category: "factual" },
  { text: "can you pick up milk", expect: "neutral", category: "factual" },
  
  // Edge cases - ambiguous
  { text: "lol ok", expect: "unclear", category: "edge_case" },
  { text: "sure thing boss", expect: "unclear", category: "edge_case" },
  { text: "absolutely perfect", expect: "unclear", category: "edge_case" },
  
  // Modern digital
  { text: "deadass this is amazing", expect: "clear", category: "modern" },
  { text: "ngl this is pretty cool", expect: "clear", category: "modern" },
  { text: "fr you're the best", expect: "clear", category: "modern" },
];

async function testMessage(text, expectation, category, testId) {
  try {
    // Add unique elements to prevent caching
    const timestamp = Date.now();
    const uniqueText = `${text} [test_${testId}_${timestamp}]`;
    
    const response = await fetch(API_BASE, {
      method: 'POST',
      headers: { 
        'Content-Type': 'application/json',
        'X-Test-ID': `test_${testId}_${timestamp}` // Unique header
      },
      body: JSON.stringify({ 
        text: uniqueText, 
        bypass_overrides: true,
        test_mode: true, // Flag to indicate this is a test
        timestamp: timestamp // Ensure request uniqueness
      }),
    });

    if (!response.ok) {
      return { error: `HTTP ${response.status}` };
    }

    const data = await response.json();
    const result = data.data;
    
    let actual = result.ui_tone;
    if (actual === 'clear') actual = 'clear';
    else if (actual === 'caution') actual = 'caution'; 
    else if (actual === 'alert') actual = 'alert';
    else actual = 'neutral';

    const matches = expectation === 'unclear' ? true : actual === expectation;
    
    return {
      text: text, // Return original text without test markers
      uniqueText: uniqueText, // Show what was actually sent
      category,
      expectation,
      actual,
      matches,
      tone: result.tone,
      confidence: result.confidence,
      distribution: result.ui_distribution,
      testId: testId,
      timestamp: timestamp
    };
  } catch (error) {
    return { error: error.message };
  }
}

async function runQuickTest() {
  console.log('🚀 QUICK PURE BASE SYSTEM TEST (Anti-Cache Version)');
  console.log('=' .repeat(60));
  console.log(`Testing ${focusedTests.length} key messages with unique identifiers`);
  console.log('⏱️  Using 1.5-second delays to prevent caching issues');
  console.log();

  const results = [];
  let passed = 0;

  for (let i = 0; i < focusedTests.length; i++) {
    const test = focusedTests[i];
    const testId = i + 1;
    
    console.log(`[${testId}/${focusedTests.length}] Testing: "${test.text}"`);
    
    const result = await testMessage(test.text, test.expect, test.category, testId);
    results.push(result);

    if (result.error) {
      console.log(`   ❌ ERROR: ${result.error}`);
    } else {
      const status = result.matches ? '✅' : '❌';
      const confidence = (result.confidence * 100).toFixed(1);
      const clear = (result.distribution.clear*100).toFixed(0);
      const caution = (result.distribution.caution*100).toFixed(0);
      const alert = (result.distribution.alert*100).toFixed(0);
      
      console.log(`   ${status} Expected: ${test.expect} → Actual: ${result.actual}`);
      console.log(`   📊 Tone: ${result.tone} (${confidence}% confidence)`);
      console.log(`   📈 Distribution: Clear ${clear}% | Caution ${caution}% | Alert ${alert}%`);
      console.log(`   🔗 Sent: "${result.uniqueText}"`);
      
      if (result.matches) passed++;
    }
    
    console.log();
    
    // Longer delay to ensure no caching
    if (i < focusedTests.length - 1) {
      console.log('⏳ Waiting 1.5 seconds to avoid cache...');
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
  }

  console.log();
  console.log('📊 DETAILED RESULTS');
  console.log('-'.repeat(40));
  console.log(`Passed: ${passed}/${focusedTests.length} (${((passed/focusedTests.length)*100).toFixed(1)}%)`);
  
  // Check for cache/duplicate issues
  const confidenceValues = results.filter(r => !r.error).map(r => r.confidence);
  const uniqueConfidences = [...new Set(confidenceValues)];
  console.log(`Unique confidence values: ${uniqueConfidences.length}/${confidenceValues.length}`);
  
  if (uniqueConfidences.length < confidenceValues.length * 0.5) {
    console.log('⚠️  WARNING: Many duplicate confidence values detected - possible caching issues');
  }
  
  const failures = results.filter(r => !r.error && !r.matches);
  if (failures.length > 0) {
    console.log();
    console.log('🚨 FAILURES:');
    failures.forEach(f => {
      console.log(`❌ "${f.text}"`);
      console.log(`   Expected: ${f.expectation} | Got: ${f.actual} | Tone: ${f.tone} (${(f.confidence*100).toFixed(1)}%)`);
    });
  }

  const edgeCases = results.filter(r => r.category === 'edge_case');
  if (edgeCases.length > 0) {
    console.log();
    console.log('🔍 EDGE CASES:');
    edgeCases.forEach(e => {
      const clear = (e.distribution.clear*100).toFixed(0);
      const caution = (e.distribution.caution*100).toFixed(0);
      const alert = (e.distribution.alert*100).toFixed(0);
      console.log(`🤔 "${e.text}" → ${e.actual} (${e.tone}) [${clear}%/${caution}%/${alert}%]`);
    });
  }

  return results;
}

// Run the quick test
runQuickTest().catch(console.error);