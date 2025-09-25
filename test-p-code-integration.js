// test-p-code-integration.js
// Quick test for P-code classification system in spacyClient

// Since we can't directly require TypeScript, let's test via the API endpoint
const http = require('http');

async function testPCodeIntegration() {
  console.log('🔬 Testing P-code integration via API...\n');

  // Test texts that should trigger different P-codes
  const testCases = [
    {
      text: "Can you clarify what you meant by that? I want to make sure I understand.",
      expectedPCodes: ['P044'], // clarity_assumption_checks
      description: "Clarity/assumption check"
    },
    {
      text: "I hear that this is frustrating for you. That makes sense given the pressure you're under.",
      expectedPCodes: ['P099'], // validation_reflective_listening
      description: "Validation/reflective listening"
    },
    {
      text: "I need to set a boundary here. I'm not available for calls after 8pm.",
      expectedPCodes: ['P061'], // boundaries_concrete_asks
      description: "Boundaries/concrete asks"
    },
    {
      text: "Let's keep this brief and focus on one topic. We can parking lot the other issues.",
      expectedPCodes: ['P031'], // thread_management_brevity
      description: "Thread management/brevity"
    }
  ];

  console.log('Testing P-code classification via tone analysis...\n');

  for (const testCase of testCases) {
    console.log(`📝 Testing: "${testCase.text}"`);
    console.log(`   Expected: ${testCase.expectedPCodes.join(', ')} (${testCase.description})`);
    
    try {
      // Test via tone analysis API which uses spacyClient
      const result = await makeApiCall('/api/v1/tone', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: testCase.text })
      });
      
      console.log(`   ✅ API Response:`, {
        ui_tone: result.ui_tone,
        // Look for P-code scores in the response
        pScores: result.analysis?.pScores,
        pTop: result.analysis?.pTop
      });
      
    } catch (error) {
      console.log(`   ❌ ERROR:`, error.message);
    }
    
    console.log('');
  }

  console.log('\n🏁 P-code integration test complete!');
}

function makeApiCall(path, options) {
  return new Promise((resolve, reject) => {
    const postData = options.body || '';
    
    const req = http.request({
      hostname: 'localhost',
      port: 3000,
      path: path,
      method: options.method || 'GET',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        ...options.headers
      }
    }, (res) => {
      let data = '';
      
      res.on('data', (chunk) => {
        data += chunk;
      });
      
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(parsed);
          } else {
            reject(new Error(`API Error ${res.statusCode}: ${parsed.error || data}`));
          }
        } catch (e) {
          reject(new Error(`Parse Error: ${data}`));
        }
      });
    });
    
    req.on('error', (err) => {
      reject(err);
    });
    
    if (postData) {
      req.write(postData);
    }
    
    req.end();
  });
}

// Run the test
console.log('Starting Vercel dev server test...');
console.log('Make sure to run "npm run dev" in another terminal first!\n');
testPCodeIntegration().catch(console.error);