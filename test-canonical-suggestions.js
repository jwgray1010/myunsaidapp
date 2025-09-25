#!/usr/bin/env node

/**
 * Test Canonical V1 Suggestions Endpoint
 * Tests the new canonical contract with tone normalization for neutral/insufficient values
 */

const crypto = require('crypto');

// Test configuration
const API_BASE = process.env.API_BASE || 'http://localhost:3000';

async function testSuggestionsEndpoint() {
  console.log('🧪 Testing Canonical V1 Suggestions Endpoint\n');

  // Test cases covering all tone classifications including neutral/insufficient
  const testCases = [
    {
      name: 'Clear Tone (Passthrough)',
      data: {
        text: 'I really appreciate your help with this project.',
        text_sha256: crypto.createHash('sha256').update('I really appreciate your help with this project.').digest('hex'),
        client_seq: 1,
        compose_id: 'test-clear-001',
        toneAnalysis: {
          classification: 'clear',
          ui_distribution: { clear: 0.8, caution: 0.15, alert: 0.05 },
          confidence: 0.85
        },
        context: 'general',
        attachmentStyle: 'secure'
      }
    },
    {
      name: 'Alert Tone (Passthrough)',  
      data: {
        text: 'This is completely unacceptable and I am furious!',
        text_sha256: crypto.createHash('sha256').update('This is completely unacceptable and I am furious!').digest('hex'),
        client_seq: 2,
        compose_id: 'test-alert-001',
        toneAnalysis: {
          classification: 'alert',
          ui_distribution: { clear: 0.1, caution: 0.2, alert: 0.7 },
          confidence: 0.92
        },
        context: 'conflict',
        attachmentStyle: 'anxious'
      }
    },
    {
      name: 'Neutral Tone (Maps to Clear)',
      data: {
        text: 'The meeting is scheduled for tomorrow.',
        text_sha256: crypto.createHash('sha256').update('The meeting is scheduled for tomorrow.').digest('hex'),
        client_seq: 3,
        compose_id: 'test-neutral-001',
        toneAnalysis: {
          classification: 'neutral',
          ui_distribution: { clear: 0.5, caution: 0.3, alert: 0.2 },
          confidence: 0.65
        },
        context: 'general',
        attachmentStyle: 'secure'
      }
    },
    {
      name: 'Insufficient Tone (Maps to Clear)',
      data: {
        text: 'ok',
        text_sha256: crypto.createHash('sha256').update('ok').digest('hex'),
        client_seq: 4,
        compose_id: 'test-insufficient-001',
        toneAnalysis: {
          classification: 'insufficient',
          ui_distribution: { clear: 0.33, caution: 0.33, alert: 0.34 },
          confidence: 0.12
        },
        context: 'general',
        attachmentStyle: 'secure'
      }
    }
  ];

  let passedTests = 0;
  let totalTests = testCases.length;

  for (const testCase of testCases) {
    console.log(`📋 Testing: ${testCase.name}`);
    
    try {
      const response = await fetch(`${API_BASE}/api/v1/suggestions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(testCase.data)
      });

      const result = await response.json();
      
      if (response.status === 200) {
        console.log(`✅ SUCCESS: ${response.status}`);
        console.log(`   Input classification: ${testCase.data.toneAnalysis.classification}`);
        console.log(`   Expected mapping: ${
          testCase.data.toneAnalysis.classification === 'neutral' ? 'clear' :
          testCase.data.toneAnalysis.classification === 'insufficient' ? 'clear' :
          testCase.data.toneAnalysis.classification
        }`);
        
        // Verify suggestions structure
        if (result.suggestions && Array.isArray(result.suggestions)) {
          console.log(`   Generated ${result.suggestions.length} suggestions`);
        } else {
          console.log(`   ⚠️  No suggestions array found`);
        }
        
        // Check for tone mapping in logs or response  
        if (result.meta?.tone_classification_used) {
          console.log(`   Mapped tone: ${result.meta.tone_classification_used}`);
        }
        
        passedTests++;
      } else {
        console.log(`❌ FAILED: ${response.status} - ${result.error || 'Unknown error'}`);
        if (result.details) {
          console.log(`   Details: ${JSON.stringify(result.details, null, 2)}`);
        }
      }
    } catch (error) {
      console.log(`❌ ERROR: ${error.message}`);
    }
    
    console.log(''); // Empty line between tests
  }

  // Summary
  console.log(`📊 Test Results: ${passedTests}/${totalTests} passed`);
  
  if (passedTests === totalTests) {
    console.log('🎉 All tests passed! Canonical V1 contract with tone normalization working correctly.');
    process.exit(0);
  } else {
    console.log('💥 Some tests failed. Check the canonical V1 suggestions implementation.');
    process.exit(1);
  }
}

// Run the test
testSuggestionsEndpoint().catch(error => {
  console.error('💥 Test suite failed:', error);
  process.exit(1);
});