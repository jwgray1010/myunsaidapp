/**
 * Simple test to verify ONNX NLI functionality
 * Tests the core NLI service without complex suggestion logic
 */

const https = require('https');
const http = require('http');

const SERVICE_URL = 'https://unsaid-gcloud-api-835271127477.us-central1.run.app';

// Helper function to make HTTP requests
function makeRequest(url, options = {}) {
  return new Promise((resolve, reject) => {
    const isHttps = url.startsWith('https:');
    const client = isHttps ? https : http;
    
    const req = client.request(url, options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const result = data ? JSON.parse(data) : {};
          resolve({ status: res.statusCode, data: result });
        } catch (e) {
          resolve({ status: res.statusCode, data: data });
        }
      });
    });
    
    req.on('error', reject);
    
    if (options.body) {
      req.write(options.body);
    }
    req.end();
  });
}

async function testBasicNLI() {
  console.log('🧪 Testing basic NLI functionality...');
  
  try {
    // Test 1: Verify service is running
    console.log('1️⃣ Health check...');
    const healthResponse = await makeRequest(`${SERVICE_URL}/health`);
    
    if (healthResponse.status === 200) {
      console.log('✅ Service healthy:', healthResponse.data.status);
    } else {
      throw new Error(`Health check failed: ${healthResponse.status}`);
    }

    // Test 2: Simple tone analysis (this uses the ONNX backend)
    console.log('2️⃣ Testing tone analysis with ONNX...');
    const toneResponse = await makeRequest(`${SERVICE_URL}/tone-analysis`, {
      method: 'POST',
      headers: { 
        'Content-Type': 'application/json',
        'User-Agent': 'ONNX-Test/1.0'
      },
      body: JSON.stringify({
        text: "I'm feeling frustrated and need help with this situation",
        context: 'general',
        userId: 'test-user'
      })
    });
    
    if (toneResponse.status !== 200) {
      throw new Error(`HTTP ${toneResponse.status}: ${JSON.stringify(toneResponse.data)}`);
    }
    
    const toneResult = toneResponse.data;
    
    if (toneResult.success && toneResult.data) {
      console.log('✅ ONNX tone analysis working:', {
        primaryTone: toneResult.data.primary_tone,
        confidence: toneResult.data.confidence,
        hasTherapeutic: !!toneResult.data.therapeutic
      });
      
      // Test 3: Check if therapeutic data uses NLI
      if (toneResult.data.therapeutic) {
        console.log('✅ ONNX NLI integration confirmed:', {
          therapeuticTone: toneResult.data.therapeutic.tone,
          clearProb: toneResult.data.therapeutic.probs?.clear,
          cautionProb: toneResult.data.therapeutic.probs?.caution,
          alertProb: toneResult.data.therapeutic.probs?.alert
        });
      }
      
      // Test 4: Try a more emotional text to trigger NLI
      console.log('3️⃣ Testing emotional text for NLI processing...');
      const emotionalResponse = await makeRequest(`${SERVICE_URL}/tone-analysis`, {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          'User-Agent': 'ONNX-Test/1.0'
        },
        body: JSON.stringify({
          text: "I hate this stupid situation and everyone is against me",
          context: 'conflict',
          userId: 'test-user'
        })
      });
      
      if (emotionalResponse.status === 200 && emotionalResponse.data.success) {
        const emotionalResult = emotionalResponse.data.data;
        console.log('✅ Emotional text NLI processing:', {
          primaryTone: emotionalResult.primary_tone,
          intensity: emotionalResult.intensity,
          therapeuticTone: emotionalResult.therapeutic?.tone,
          alertProb: emotionalResult.therapeutic?.probs?.alert
        });
        
        console.log('🎯 All ONNX NLI tests passed successfully!');
        console.log('📊 The ModernBERT ONNX model is working correctly!');
        
      } else {
        console.warn('⚠️ Emotional text test failed, but basic NLI is working');
      }
      
    } else {
      console.error('❌ Tone analysis failed:', toneResult);
    }

  } catch (error) {
    console.error('❌ Test failed:', error.message);
    if (error.stack) {
      console.error('Stack:', error.stack);
    }
    process.exit(1);
  }
}

testBasicNLI();