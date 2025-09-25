const crypto = require('crypto');

// Simple test script to debug suggestions endpoint
async function testSuggestionsEndpoint() {
  const testText = "We're fighting and I need help calming things down";
  const textHash = crypto.createHash('sha256').update(testText, 'utf8').digest('hex');
  
  const testPayload = {
    text: testText,
    text_sha256: textHash,
    client_seq: 1,
    compose_id: 'debug-test-1',
    toneAnalysis: {
      classification: 'caution',
      confidence: 0.75,
      ui_distribution: { clear: 0.2, caution: 0.6, alert: 0.2 },
      intensity: 0.7
    },
    context: 'conflict',
    attachmentStyle: 'secure'
  };
  
  console.log('🧪 Testing suggestions endpoint with payload:');
  console.log(JSON.stringify(testPayload, null, 2));
  
  try {
    const response = await fetch('http://localhost:3000/api/v1/suggestions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-user-id': 'debug-user'
      },
      body: JSON.stringify(testPayload)
    });
    
    console.log(`\n🔍 Response status: ${response.status}`);
    const result = await response.json();
    console.log('\n📊 Response body:');
    console.log(JSON.stringify(result, null, 2));
    
    if (result.suggestions && result.suggestions.length > 0) {
      console.log(`\n✅ SUCCESS: ${result.suggestions.length} suggestions returned`);
    } else {
      console.log('\n⚠️ ISSUE: No suggestions returned');
      console.log('Checking analysis_meta for clues...');
      if (result.analysis_meta) {
        console.log('Analysis meta:', JSON.stringify(result.analysis_meta, null, 2));
      }
    }
    
  } catch (error) {
    console.error('❌ Error testing endpoint:', error.message);
  }
}

// Run the test
testSuggestionsEndpoint();