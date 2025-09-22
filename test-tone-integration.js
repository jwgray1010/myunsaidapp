#!/usr/bin/env node
/**
 * Integration test script for enhanced tone analysis system
 * Tests the complete pipeline: JSON loading -> TypeScript service -> API response
 */

const http = require('http');

const testCases = [
  {
    name: "Aggressive text (should be ALERT)",
    text: "I hate everything about you! You are the worst",
    expected: "alert",
    context: "conflict"
  },
  {
    name: "Profanity with emoji (should be ALERT)", 
    text: "This is fucking bullshit 🤬",
    expected: "alert",
    context: "conflict"
  },
  {
    name: "Sarcastic dismissal (should be CAUTION/ALERT)",
    text: "Whatever 🙄 sure thing buddy",
    expected: "caution",
    context: "conflict"
  },
  {
    name: "Multi-word relationship pattern (should be ALERT)",
    text: "You never listen to me, we're done",
    expected: "alert", 
    context: "conflict"
  },
  {
    name: "Positive supportive text (should be CLEAR)",
    text: "I love you and appreciate everything you do",
    expected: "clear",
    context: "general"
  },
  {
    name: "Gentle suggestion (should be CLEAR)",
    text: "Maybe we could try a different approach?",
    expected: "clear",
    context: "repair"
  }
];

async function testToneAPI(baseUrl = 'https://api.myunsaidapp.com') {
  console.log('🧪 TESTING ENHANCED TONE ANALYSIS SYSTEM');
  console.log('=' * 50);
  console.log(`Target: ${baseUrl}/api/v1/tone`);
  console.log('');

  for (const testCase of testCases) {
    console.log(`Testing: ${testCase.name}`);
    console.log(`Text: "${testCase.text}"`);
    console.log(`Expected: ${testCase.expected.toUpperCase()}`);
    
    const payload = {
      text: testCase.text,
      context: testCase.context,
      attachmentStyle: "anxious",
      includeSuggestions: true,
      includeEmotions: true
    };

    try {
      const response = await makeRequest(`${baseUrl}/api/v1/tone`, payload);
      
      if (response.ok) {
        const actual = response.ui_tone || 'unknown';
        const confidence = response.confidence || 0;
        const tone = response.tone || 'unknown';
        
        const status = actual === testCase.expected ? '✅ PASS' : '❌ FAIL';
        console.log(`Result: ${status} - ${actual.toUpperCase()} (confidence: ${confidence.toFixed(3)})`);
        console.log(`Classifier tone: ${tone}`);
        
        if (response.ui_distribution) {
          const dist = response.ui_distribution;
          console.log(`Distribution: clear:${(dist.clear||0).toFixed(3)} caution:${(dist.caution||0).toFixed(3)} alert:${(dist.alert||0).toFixed(3)}`);
        }
      } else {
        console.log('❌ FAIL - API Error:', response.error || 'Unknown error');
      }
    } catch (error) {
      console.log('❌ FAIL - Request Error:', error.message);
    }
    
    console.log('');
  }
}

function makeRequest(url, payload) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    const urlObj = new URL(url);
    
    const options = {
      hostname: urlObj.hostname,
      port: urlObj.port,
      path: urlObj.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data)
      }
    };

    const req = http.request(options, (res) => {
      let body = '';
      res.on('data', (chunk) => body += chunk);
      res.on('end', () => {
        try {
          const response = JSON.parse(body);
          resolve(response);
        } catch (e) {
          reject(new Error(`Invalid JSON response: ${body}`));
        }
      });
    });

    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// Export for programmatic use or run directly
if (require.main === module) {
  const baseUrl = process.argv[2] || 'https://api.myunsaidapp.com';
  testToneAPI(baseUrl).catch(console.error);
}

module.exports = { testToneAPI, testCases };