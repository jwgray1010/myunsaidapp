// test-micro-advice-integration.js
/**
 * Test script for micro-advice integration in suggestions API
 * Tests the new attachment-pattern additive functionality
 */

const axios = require('axios');

// Configuration
const BASE_URL = process.env.API_BASE_URL || 'http://localhost:3000';
const API_KEY = process.env.UNSAID_API_KEY || 'test-key';

const testCases = [
  {
    name: 'Anxious Pattern Detection',
    input: {
      text: "I keep checking if my messages were read and I'm getting really anxious",
      context: "anxious.pattern",
      attachmentStyle: "anxious"
    },
    expectations: {
      shouldHaveMicroAdvice: true,
      expectedPatterns: ['anxious.pattern'],
      expectedIntents: ['regulate', 'clarify']
    }
  },
  {
    name: 'Conflict with Pattern Awareness',
    input: {
      text: "We're having the same fight again and I don't know how to break the cycle",
      context: "conflict",
      attachmentStyle: "disorganized"
    },
    expectations: {
      shouldHaveMicroAdvice: true,
      expectedContexts: ['conflict'],
      expectedIntents: ['deescalate', 'interrupt_spiral']
    }
  },
  {
    name: 'General Communication',
    input: {
      text: "How should I respond to this message?",
      context: "general",
      attachmentStyle: "secure"
    },
    expectations: {
      shouldHaveMicroAdvice: true,
      expectedContexts: ['general']
    }
  }
];

async function testSuggestionsAPI(testCase) {
  try {
    console.log(`\n🧪 Testing: ${testCase.name}`);
    console.log(`📝 Input: "${testCase.input.text}"`);
    
    const response = await axios.post(`${BASE_URL}/api/v1/suggestions`, {
      text: testCase.input.text,
      context: testCase.input.context,
      attachment_style: testCase.input.attachmentStyle,
      user_id: 'test-user-micro-advice'
    }, {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${API_KEY}`
      }
    });

    if (response.status !== 200) {
      throw new Error(`API returned status ${response.status}`);
    }

    const result = response.data;
    console.log(`✅ API Response received`);
    
    // Check for micro-advice suggestions
    const suggestions = result.suggestions || [];
    const microAdvice = suggestions.filter(s => s.type === 'micro_advice');
    const rewriteSuggestions = suggestions.filter(s => s.type !== 'micro_advice');
    
    console.log(`📊 Total suggestions: ${suggestions.length}`);
    console.log(`🎯 Micro-advice count: ${microAdvice.length}`);
    console.log(`✏️  Rewrite suggestions: ${rewriteSuggestions.length}`);
    
    // Validate expectations
    let passed = true;
    
    if (testCase.expectations.shouldHaveMicroAdvice && microAdvice.length === 0) {
      console.log(`❌ Expected micro-advice but got none`);
      passed = false;
    }
    
    if (microAdvice.length > 0) {
      console.log(`\n🔍 Micro-advice details:`);
      microAdvice.forEach((advice, i) => {
        console.log(`  ${i + 1}. "${advice.advice || advice.text}"`);
        if (advice.meta) {
          console.log(`     Contexts: ${advice.meta.contexts?.join(', ') || 'none'}`);
          console.log(`     Intents: ${advice.meta.intent?.join(', ') || 'none'}`);
          console.log(`     Patterns: ${advice.meta.patterns?.join(', ') || 'none'}`);
          console.log(`     Trigger Tone: ${advice.meta.triggerTone || 'none'}`);
        }
      });
      
      // Check pattern expectations
      if (testCase.expectations.expectedPatterns) {
        const foundPatterns = microAdvice.flatMap(a => a.meta?.patterns || []);
        const hasExpectedPatterns = testCase.expectations.expectedPatterns.some(p => 
          foundPatterns.includes(p)
        );
        if (!hasExpectedPatterns) {
          console.log(`❌ Expected patterns ${testCase.expectations.expectedPatterns.join(', ')} but found ${foundPatterns.join(', ')}`);
          passed = false;
        }
      }
      
      // Check intent expectations  
      if (testCase.expectations.expectedIntents) {
        const foundIntents = microAdvice.flatMap(a => a.meta?.intent || []);
        const hasExpectedIntents = testCase.expectations.expectedIntents.some(i => 
          foundIntents.includes(i)
        );
        if (!hasExpectedIntents) {
          console.log(`❌ Expected intents ${testCase.expectations.expectedIntents.join(', ')} but found ${foundIntents.join(', ')}`);
          passed = false;
        }
      }
    }
    
    if (passed) {
      console.log(`✅ Test passed: ${testCase.name}`);
    } else {
      console.log(`❌ Test failed: ${testCase.name}`);
    }
    
    return { passed, microAdviceCount: microAdvice.length, totalSuggestions: suggestions.length };
    
  } catch (error) {
    console.log(`❌ Test failed with error: ${testCase.name}`);
    console.log(`   Error: ${error.message}`);
    if (error.response?.data) {
      console.log(`   Response: ${JSON.stringify(error.response.data, null, 2)}`);
    }
    return { passed: false, error: error.message };
  }
}

async function runTests() {
  console.log('🚀 Starting Micro-Advice Integration Tests');
  console.log(`🌐 API Base URL: ${BASE_URL}`);
  
  const results = [];
  
  for (const testCase of testCases) {
    const result = await testSuggestionsAPI(testCase);
    results.push({ name: testCase.name, ...result });
    
    // Small delay between tests
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  
  // Summary
  console.log('\n📋 Test Summary:');
  const passed = results.filter(r => r.passed).length;
  const total = results.length;
  
  results.forEach(result => {
    const status = result.passed ? '✅' : '❌';
    const details = result.microAdviceCount !== undefined ? 
      ` (${result.microAdviceCount} micro-advice, ${result.totalSuggestions} total)` : '';
    console.log(`  ${status} ${result.name}${details}`);
  });
  
  console.log(`\n🎯 Results: ${passed}/${total} tests passed`);
  
  if (passed === total) {
    console.log('🎉 All tests passed! Micro-advice integration is working correctly.');
  } else {
    console.log('⚠️  Some tests failed. Check the logs above for details.');
    process.exit(1);
  }
}

// Run the tests
if (require.main === module) {
  runTests().catch(error => {
    console.error('💥 Test runner failed:', error);
    process.exit(1);
  });
}

module.exports = { testSuggestionsAPI, runTests };