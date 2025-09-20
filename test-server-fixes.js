// Test script for server-side fixes
// Run with: node test-server-fixes.js

const baseURL = 'https://api.myunsaidapp.com/api/v1/tone';

async function testToneEndpoint(text, expectedUITone, testName) {
  try {
    const response = await fetch(baseURL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        text,
        client_seq: Math.floor(Math.random() * 1000)
      })
    });

    const result = await response.json();
    
    // Handle wrapped response format
    const data = result.success ? result.data : result;
    
    console.log(`\n=== ${testName} ===`);
    console.log(`Input: "${text}"`);
    console.log(`Expected: ${expectedUITone}`);
    console.log(`Actual: ${data.ui_tone}`);
    console.log(`Buckets: clear=${data.ui_distribution?.clear?.toFixed(2)}, caution=${data.ui_distribution?.caution?.toFixed(2)}, alert=${data.ui_distribution?.alert?.toFixed(2)}`);
    console.log(`Confidence: ${data.confidence?.toFixed(3) || 'N/A'}`);
    console.log(`Reason: ${data.reason || 'N/A'}`);
    console.log(`Processing time: ${data.metadata?.processingTimeMs || 'N/A'}ms`);
    
    const passed = data.ui_tone === expectedUITone;
    console.log(`✅ ${passed ? 'PASS' : 'FAIL'}: ${testName}`);
    
    return passed;
    
  } catch (error) {
    console.log(`❌ ERROR: ${testName} - ${error.message}`);
    return false;
  }
}

async function testDuplicateRequests() {
  const text = "You are amazing";
  const clientSeq = 12345;
  
  console.log(`\n=== Testing Duplicate Request Prevention ===`);
  
  const startTime = Date.now();
  
  // Send same request twice rapidly
  const [response1, response2] = await Promise.all([
    fetch(baseURL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, client_seq: clientSeq })
    }),
    fetch(baseURL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, client_seq: clientSeq })
    })
  ]);
  
  const result1 = await response1.json();
  const result2 = await response2.json();
  
  // Handle wrapped response format
  const data1 = result1.success ? result1.data : result1;
  const data2 = result2.success ? result2.data : result2;
  
  const time1 = data1.metadata?.processingTimeMs || 0;
  const time2 = data2.metadata?.processingTimeMs || 0;
  
  console.log(`Response 1 time: ${time1}ms`);
  console.log(`Response 2 time: ${time2}ms`);
  
  // If idempotency works, second request should be much faster (cached)
  const cacheHit = Math.abs(time1 - time2) > 50; // Significant time difference indicates caching
  console.log(`✅ ${cacheHit ? 'PASS' : 'FAIL'}: Duplicate request optimization`);
  
  return cacheHit;
}

async function runAllTests() {
  console.log('🧪 Testing Server-Side Fixes for Tone Analysis\n');
  
  const tests = [
    // Short text gating
    () => testToneEndpoint("Fu", "insufficient", "Short text 'Fu' should be insufficient"),
    () => testToneEndpoint("Y", "insufficient", "Single char 'Y' should be insufficient"),
    () => testToneEndpoint("Hi", "insufficient", "Two chars 'Hi' should be insufficient"),
    
    // Profanity prefix awareness
    () => testToneEndpoint("Fuck", "caution", "Full profanity 'Fuck' should be caution/alert"),
    () => testToneEndpoint("Fu you", "caution", "Profanity prefix 'Fu you' should be caution"),
    () => testToneEndpoint("Shit happens", "caution", "Full profanity 'Shit happens' should be caution/alert"),
    
    // Meta-classifier and confidence gating
    () => testToneEndpoint("You are the worst", "caution", "Negative phrase should be caution/alert"),
    () => testToneEndpoint("I love you so much", "clear", "Positive phrase should be clear"),
    () => testToneEndpoint("Maybe we could talk about this", "clear", "Neutral collaborative phrase should be clear"),
    
    // Edge cases
    () => testToneEndpoint("", "insufficient", "Empty text should be insufficient"),
    () => testToneEndpoint("   ", "insufficient", "Whitespace only should be insufficient"),
    
    // Duplicate request test
    testDuplicateRequests
  ];
  
  let passed = 0;
  let total = tests.length;
  
  for (const test of tests) {
    const result = await test();
    if (result) passed++;
    
    // Small delay between tests
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  
  console.log(`\n📊 Test Results: ${passed}/${total} tests passed`);
  
  if (passed === total) {
    console.log('🎉 All tests passed! Server fixes are working correctly.');
  } else {
    console.log('⚠️  Some tests failed. Check the implementation.');
  }
}

// Run the tests
runAllTests().catch(console.error);