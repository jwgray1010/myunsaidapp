// test-full-text-mode.js - Test full-text document analysis
const fetch = require('node-fetch');

const API_BASE = process.env.UNSAID_API_BASE_URL || 'http://localhost:3000';

async function testFullTextMode() {
  console.log('🧪 Testing Full-Text Document Analysis Mode');
  console.log('============================================\n');

  // Test document with escalatory pattern
  const testDocument = `I understand you're frustrated, but I need to point out that you always do this. 
Every time we discuss something important, you shut down completely. 
It's really difficult to have a productive conversation when you won't engage. 
I love you and I care about our relationship, but this pattern is becoming a problem.`;

  const textHash = require('crypto').createHash('sha256').update(testDocument).digest('hex');
  const docSeq = 1;

  const payload = {
    mode: 'full',
    text: testDocument,
    context: 'relationship',
    doc_seq: docSeq,
    text_hash: textHash
  };

  try {
    console.log('📄 Testing full-text mode with document-level analysis...');
    console.log(`Text length: ${testDocument.length} characters`);
    console.log(`Doc sequence: ${docSeq}`);
    console.log(`Text hash: ${textHash.slice(0, 16)}...`);
    console.log('');

    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-user-id': 'test-full-mode-user'
      },
      body: JSON.stringify(payload)
    });

    const result = await response.json();

    if (!response.ok) {
      console.log('❌ Request failed:', result);
      return;
    }

    // Handle wrapped response format
    const data = result.success ? result.data : result;

    console.log('✅ Full-text analysis successful!');
    console.log('');
    console.log('📊 Results:');
    console.log(`Mode: ${data.mode || 'legacy'}`);
    console.log(`Doc Tone: ${data.doc_tone || data.ui_tone}`);
    console.log(`Primary Tone: ${data.tone}`);
    console.log(`Confidence: ${data.confidence}`);
    console.log(`Doc Seq: ${data.doc_seq}`);
    console.log(`Text Hash: ${data.text_hash?.slice(0, 16)}...`);
    console.log('');
    
    console.log('🔍 UI Distribution:');
    if (data.ui_distribution) {
      console.log(`  Clear: ${(data.ui_distribution.clear * 100).toFixed(1)}%`);
      console.log(`  Caution: ${(data.ui_distribution.caution * 100).toFixed(1)}%`);
      console.log(`  Alert: ${(data.ui_distribution.alert * 100).toFixed(1)}%`);
    }
    console.log('');

    if (data.document_analysis) {
      console.log('🛡️ Document Analysis:');
      console.log(`  Safety Gate Applied: ${data.document_analysis.safety_gate_applied}`);
      console.log(`  Analysis Type: ${data.document_analysis.analysis_type}`);
      if (data.document_analysis.safety_reason) {
        console.log(`  Safety Reason: ${data.document_analysis.safety_reason}`);
        console.log(`  Original Tone: ${data.document_analysis.original_tone}`);
      }
      console.log('');
    }

    console.log(`⏱️ Processing Time: ${data.metadata?.processingTimeMs}ms`);
    console.log(`🤖 Model Version: ${data.metadata?.model_version}`);

    // Test hash mismatch validation
    console.log('\n🧪 Testing hash mismatch validation...');
    const invalidPayload = {
      ...payload,
      text_hash: 'invalid_hash_should_fail'
    };

    const invalidResponse = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-user-id': 'test-full-mode-user'
      },
      body: JSON.stringify(invalidPayload)
    });

    if (invalidResponse.ok) {
      console.log('❌ Hash validation failed - should have rejected invalid hash');
    } else {
      console.log('✅ Hash validation working - correctly rejected invalid hash');
    }

    // Test idempotency
    console.log('\n🧪 Testing idempotency...');
    const startTime = Date.now();
    const idempotentResponse = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-user-id': 'test-full-mode-user'
      },
      body: JSON.stringify(payload)
    });

    const idempotentResult = await idempotentResponse.json();
    const responseTime = Date.now() - startTime;

    // Handle wrapped response format
    const idempotentData = idempotentResult.success ? idempotentResult.data : idempotentResult;

    if (idempotentData.doc_seq === docSeq && responseTime < 50) {
      console.log('✅ Idempotency working - fast cached response');
      console.log(`⚡ Cache response time: ${responseTime}ms`);
    } else {
      console.log('❌ Idempotency may not be working correctly');
    }

  } catch (error) {
    console.error('❌ Test failed:', error.message);
  }
}

// Test legacy mode compatibility
async function testLegacyMode() {
  console.log('\n🧪 Testing Legacy Mode Compatibility');
  console.log('=====================================\n');

  const payload = {
    text: "This is a test message",
    context: 'general',
    client_seq: 42
  };

  try {
    const response = await fetch(`${API_BASE}/api/v1/tone`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-user-id': 'test-legacy-user'
      },
      body: JSON.stringify(payload)
    });

    const result = await response.json();

    // Handle wrapped response format
    const data = result.success ? result.data : result;

    if (response.ok) {
      console.log('✅ Legacy mode still working');
      console.log(`Mode: ${data.mode || 'legacy (implicit)'}`);
      console.log(`UI Tone: ${data.ui_tone}`);
      console.log(`Client Seq: ${data.client_seq}`);
    } else {
      console.log('❌ Legacy mode failed:', result);
    }

  } catch (error) {
    console.error('❌ Legacy test failed:', error.message);
  }
}

// Run tests
testFullTextMode().then(() => testLegacyMode());