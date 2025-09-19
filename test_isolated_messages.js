#!/usr/bin/env node

// Test isolated messages by resetting conversation memory between calls
const API_BASE = process.env.API_BASE || 'http://localhost:3001';
const API_KEY = process.env.API_KEY || 'dev-key-12345';

const testMessages = [
  { text: "this is amazing", expected: "clear", description: "Positive enthusiasm" },
  { text: "you did such a great job", expected: "clear", description: "Positive praise" },
  { text: "I really appreciate you", expected: "clear", description: "Supportive appreciation" },
  { text: "whatever", expected: "caution", description: "Dismissive word" },
  { text: "I hate you", expected: "alert", description: "Direct hostility" },
  { text: "the meeting is at 3pm", expected: "neutral", description: "Neutral information" }
];

async function testMessage(message, index) {
  const uniqueId = `test_isolated_${index}_${Date.now()}`;
  
  try {
    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${API_KEY}`
      },
      body: JSON.stringify({
        text: `${message.text} [${uniqueId}]`,
        context: 'general',
        reset_memory: true,  // Reset conversation memory for isolation
        field_id: uniqueId,
        bypass_overrides: false
      })
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const result = await response.json();
    const uiTone = result.ui_tone || 'unknown';
    const distribution = result.ui_distribution || {};
    const analysis = result.analysis || {};
    
    const isCorrect = uiTone === message.expected;
    const status = isCorrect ? '✅' : '❌';
    
    console.log(`[${index + 1}/6] ${status} "${message.text}"`);
    console.log(`   Expected: ${message.expected} → Actual: ${uiTone}`);
    console.log(`   📊 Tone: ${analysis.primary_tone} (${(analysis.confidence * 100).toFixed(1)}% confidence)`);
    console.log(`   📈 Distribution: Clear ${Math.round(distribution.clear * 100)}% | Caution ${Math.round(distribution.caution * 100)}% | Alert ${Math.round(distribution.alert * 100)}%`);
    console.log(`   🔗 Sent: "${message.text} [${uniqueId}]"`);
    console.log();
    
    return { message, expected: message.expected, actual: uiTone, isCorrect, result };
    
  } catch (error) {
    console.error(`❌ Failed to test "${message.text}": ${error.message}`);
    return { message, expected: message.expected, actual: 'error', isCorrect: false, error };
  }
}

async function runIsolatedTests() {
  console.log('🧪 ISOLATED MESSAGE TESTS (Memory Reset Between Calls)');
  console.log('=====================================================');
  console.log('Testing with conversation memory reset to prevent contamination');
  console.log();
  
  const results = [];
  
  for (let i = 0; i < testMessages.length; i++) {
    const result = await testMessage(testMessages[i], i);
    results.push(result);
    
    // Small delay to ensure proper isolation
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  
  console.log('📊 ISOLATED TEST RESULTS');
  console.log('-------------------------');
  const passed = results.filter(r => r.isCorrect).length;
  console.log(`Passed: ${passed}/${results.length} (${Math.round(passed/results.length*100)}%)`);
  
  const failed = results.filter(r => !r.isCorrect);
  if (failed.length > 0) {
    console.log();
    console.log('🚨 FAILURES:');
    failed.forEach(f => {
      console.log(`❌ "${f.message.text}"`);
      console.log(`   Expected: ${f.expected} | Got: ${f.actual}`);
    });
  }
  
  // Check for consistency (same messages should get same results)
  const confidenceValues = results.map(r => r.result?.analysis?.confidence || 0);
  const uniqueConfidences = [...new Set(confidenceValues.map(c => c.toFixed(3)))];
  console.log();
  console.log(`🎯 Confidence diversity: ${uniqueConfidences.length}/${results.length} unique values`);
  if (uniqueConfidences.length < results.length * 0.5) {
    console.log('⚠️  WARNING: Low confidence diversity suggests systematic issues');
  }
}

runIsolatedTests().catch(console.error);