#!/usr/bin/env node

/**
 * Comprehensive test suite for pure base tone classifications
 * Tests various message categories to find where base system works vs needs overrides
 */

const API_BASE = 'https://api.myunsaidapp.com/api/v1/tone';

// Test categories with expected outcomes
const testCategories = {
  // Should be CLEAR (positive, supportive)
  genuinely_positive: [
    { text: "this is amazing", expect: "clear" },
    { text: "you did such a great job", expect: "clear" },
    { text: "I love spending time with you", expect: "clear" },
    { text: "thank you so much for helping", expect: "clear" },
    { text: "I really appreciate you", expect: "clear" },
    { text: "that was thoughtful of you", expect: "clear" },
    { text: "I'm proud of you", expect: "clear" },
    { text: "you make me happy", expect: "clear" },
  ],

  // Should be CAUTION (passive-aggressive, dismissive)
  passive_aggressive: [
    { text: "I'm fine", expect: "caution" },
    { text: "whatever", expect: "caution" },
    { text: "sure, if you say so", expect: "caution" },
    { text: "I guess that's fine", expect: "caution" },
    { text: "thanks for nothing", expect: "caution" },
    { text: "that's just great", expect: "caution" }, // sarcasm test
    { text: "oh wonderful", expect: "caution" }, // sarcasm test
    { text: "perfect timing as always", expect: "caution" }, // sarcasm test
  ],

  // Should be ALERT (hostile, toxic)
  hostile_toxic: [
    { text: "you're such an idiot", expect: "alert" },
    { text: "I hate you", expect: "alert" },
    { text: "shut up", expect: "alert" },
    { text: "you always mess everything up", expect: "alert" },
    { text: "you never listen to me", expect: "alert" },
    { text: "this is all your fault", expect: "alert" },
  ],

  // Should be NEUTRAL (informational, factual)
  neutral_factual: [
    { text: "the meeting is at 3pm", expect: "neutral" },
    { text: "I'll be there in 10 minutes", expect: "neutral" },
    { text: "can you pick up milk", expect: "neutral" },
    { text: "the weather is nice today", expect: "neutral" },
    { text: "I finished the project", expect: "neutral" },
  ],

  // EDGE CASES - where base system might struggle
  potential_edge_cases: [
    { text: "lol ok", expect: "unclear" }, // ambiguous
    { text: "k", expect: "unclear" }, // minimal response
    { text: "mhm", expect: "unclear" }, // minimal acknowledgment
    { text: "sure thing boss", expect: "unclear" }, // could be genuine or sarcastic
    { text: "absolutely perfect", expect: "unclear" }, // could be genuine enthusiasm or sarcasm
    { text: "wow just wow", expect: "unclear" }, // could be amazed or disgusted
    { text: "that's something", expect: "unclear" }, // vague, could be positive or negative
    { text: "interesting choice", expect: "unclear" }, // diplomatic disapproval?
  ],

  // MODERN DIGITAL - test the enhanced modifiers
  modern_digital: [
    { text: "deadass this is amazing", expect: "clear" },
    { text: "ngl this is pretty cool", expect: "clear" },
    { text: "fr you're the best", expect: "clear" },
    { text: "lowkey proud of you", expect: "clear" },
    { text: "periodt that was fire", expect: "clear" },
    { text: "no cap you killed it", expect: "clear" },
  ],
};

async function testMessage(text, expectation, category) {
  try {
    const response = await fetch(API_BASE, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ 
        text: text, 
        bypass_overrides: true // Test pure base system
      }),
    });

    if (!response.ok) {
      return { error: `HTTP ${response.status}` };
    }

    const data = await response.json();
    const result = data.data;
    
    // Determine actual outcome based on UI tone
    let actual = result.ui_tone;
    if (actual === 'clear') actual = 'clear';
    else if (actual === 'caution') actual = 'caution'; 
    else if (actual === 'alert') actual = 'alert';
    else actual = 'neutral';

    // Check if it matches expectation
    const matches = expectation === 'unclear' ? true : actual === expectation;
    
    return {
      text,
      category,
      expectation,
      actual,
      matches,
      tone: result.tone,
      confidence: result.confidence,
      distribution: result.ui_distribution,
      processingTime: result.metadata?.processingTimeMs
    };
  } catch (error) {
    return { error: error.message };
  }
}

async function runComprehensiveTest() {
  console.log('🧪 COMPREHENSIVE PURE BASE TONE ANALYSIS TEST');
  console.log('=' .repeat(60));
  console.log('⏱️  Running with 1-second delays between requests to respect rate limits');
  console.log();

  const allResults = [];
  let totalTests = 0;
  let passedTests = 0;

  for (const [categoryName, tests] of Object.entries(testCategories)) {
    console.log(`📂 Category: ${categoryName.toUpperCase()}`);
    console.log('-'.repeat(40));

    for (const test of tests) {
      totalTests++;
      console.log(`Testing: "${test.text}"`);
      
      const result = await testMessage(test.text, test.expect, categoryName);
      allResults.push(result);

      if (result.error) {
        console.log(`   ❌ ERROR: ${result.error}`);
      } else {
        const status = result.matches ? '✅' : '❌';
        const confidence = (result.confidence * 100).toFixed(1);
        
        console.log(`   ${status} Expected: ${test.expect} | Actual: ${result.actual} | Tone: ${result.tone} | Confidence: ${confidence}%`);
        console.log(`   📊 Distribution: Clear ${(result.distribution.clear*100).toFixed(1)}% | Caution ${(result.distribution.caution*100).toFixed(1)}% | Alert ${(result.distribution.alert*100).toFixed(1)}%`);
        
        if (result.matches) passedTests++;
      }
      console.log();
      
      // 1 second delay between requests to respect rate limits
      console.log('⏳ Waiting 1 second...');
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    
    // Longer break between categories
    if (categoryName !== Object.keys(testCategories).pop()) {
      console.log('🔄 Category complete. Taking 2-second break before next category...');
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
    console.log();
  }

  // Summary report
  console.log('📊 SUMMARY REPORT');
  console.log('=' .repeat(60));
  console.log(`Total Tests: ${totalTests}`);
  console.log(`Passed: ${passedTests}`);
  console.log(`Failed: ${totalTests - passedTests}`);
  console.log(`Success Rate: ${((passedTests / totalTests) * 100).toFixed(1)}%`);
  console.log();

  // Failure analysis
  const failures = allResults.filter(r => !r.error && !r.matches);
  if (failures.length > 0) {
    console.log('🚨 FAILURES ANALYSIS - Where base system needs help:');
    console.log('-'.repeat(50));
    failures.forEach(f => {
      console.log(`❌ "${f.text}"`);
      console.log(`   Expected: ${f.expectation} | Got: ${f.actual} | Tone: ${f.tone}`);
      console.log(`   Category: ${f.category}`);
      console.log();
    });
  }

  // Edge case analysis
  const edgeCases = allResults.filter(r => r.category === 'potential_edge_cases');
  if (edgeCases.length > 0) {
    console.log('🔍 EDGE CASE ANALYSIS - Ambiguous messages:');
    console.log('-'.repeat(50));
    edgeCases.forEach(e => {
      console.log(`🤔 "${e.text}"`);
      console.log(`   Classified as: ${e.actual} (${e.tone}) | Confidence: ${(e.confidence*100).toFixed(1)}%`);
      console.log(`   Distribution: Clear ${(e.distribution.clear*100).toFixed(1)}% | Caution ${(e.distribution.caution*100).toFixed(1)}% | Alert ${(e.distribution.alert*100).toFixed(1)}%`);
      console.log();
    });
  }

  return allResults;
}

// Run the test
runComprehensiveTest().catch(console.error);