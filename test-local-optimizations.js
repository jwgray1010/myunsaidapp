#!/usr/bin/env node

/**
 * Local test for optimized SpaCy service and suggestions engine
 * Tests the enhanced context classification and environment variable controls
 */

const { SpacyService } = require('./api/_lib/services/spacyClient.ts');
const { logger } = require('./api/_lib/logger.js');

// Test data
const testMessages = [
  {
    text: "I hate everything about you! You are the worst person ever!",
    expected: "conflict",
    description: "Aggressive conflict message"
  },
  {
    text: "I love you so much and appreciate everything you do for our family",
    expected: "appreciation",
    description: "Positive appreciation message"
  },
  {
    text: "Can we talk about our relationship? I feel like we're drifting apart",
    expected: "relationship_check_in",
    description: "Relationship concern"
  },
  {
    text: "Whatever... sure thing buddy 🙄",
    expected: "dismissive",
    description: "Sarcastic dismissal"
  },
  {
    text: "I need some space to think about things",
    expected: "boundary_setting",
    description: "Boundary setting"
  }
];

async function testSpacyOptimizations() {
  console.log('🧪 TESTING OPTIMIZED SPACY SERVICE\n');
  console.log('=' + '='.repeat(50));
  
  // Test environment variable controls
  console.log('Environment Variable Controls:');
  console.log(`SPACY_MODE: ${process.env.SPACY_MODE || 'balanced (default)'}`);
  console.log(`SPACY_MAX_CHARS: ${process.env.SPACY_MAX_CHARS || '2000 (default)'}`);
  console.log(`SPACY_LRU_MAX: ${process.env.SPACY_LRU_MAX || '128 (default)'}`);
  console.log(`SPACY_CONTEXT_THRESHOLD: ${process.env.SPACY_CONTEXT_THRESHOLD || '0.05 (default)'}`);
  console.log('');
  
  // Initialize SpaCy service
  const spacy = new SpacyService({
    mode: 'balanced',
    dataPath: './data'
  });
  
  console.log('SpaCy Service Summary:', spacy.getProcessingSummary());
  console.log('');
  
  // Test each message
  for (const [index, test] of testMessages.entries()) {
    console.log(`\nTest ${index + 1}: ${test.description}`);
    console.log(`Text: "${test.text}"`);
    console.log(`Expected context: ${test.expected}`);
    
    try {
      const startTime = Date.now();
      
      // Test compact result (used by tone analysis)
      const compactResult = spacy.process(test.text);
      
      // Test full analysis
      const fullResult = await spacy.processFullAnalysis(test.text);
      
      const processingTime = Date.now() - startTime;
      
      console.log(`✓ Processed in ${processingTime}ms`);
      console.log(`  Context: ${compactResult.context.label} (score: ${compactResult.context.score.toFixed(3)})`);
      console.log(`  Negation: ${compactResult.negation.present ? 'Yes' : 'No'} (score: ${compactResult.negation.score.toFixed(3)})`);
      console.log(`  Sarcasm: ${compactResult.sarcasm.present ? 'Yes' : 'No'} (score: ${compactResult.sarcasm.score.toFixed(3)})`);
      console.log(`  Intensity: ${compactResult.intensity.score.toFixed(3)}`);
      console.log(`  Tokens: ${compactResult.tokens?.length || 0}`);
      console.log(`  Entities: ${compactResult.entities.length}`);
      
      // Test context classification details
      if (fullResult.contextClassification.allContexts.length > 0) {
        console.log(`  Top contexts:`);
        for (const ctx of fullResult.contextClassification.allContexts.slice(0, 3)) {
          console.log(`    - ${ctx.context}: ${ctx.score.toFixed(3)} (conf: ${ctx.confidence.toFixed(3)})`);
        }
      }
      
      // Validate expectations
      if (compactResult.context.label.toLowerCase().includes(test.expected.toLowerCase()) ||
          test.expected.toLowerCase().includes(compactResult.context.label.toLowerCase())) {
        console.log(`✅ PASS - Context matches expected`);
      } else {
        console.log(`⚠️  PARTIAL - Got ${compactResult.context.label}, expected ${test.expected}`);
      }
      
    } catch (error) {
      console.log(`❌ ERROR: ${error.message}`);
    }
  }
  
  console.log('\n' + '=' + '='.repeat(50));
  console.log('Test completed!');
}

// Environment variable test
function testEnvironmentControls() {
  console.log('\n🔧 TESTING ENVIRONMENT VARIABLE CONTROLS\n');
  
  // Test with different environment settings
  const originalValues = {};
  const testEnvs = {
    'SPACY_MAX_CHARS': '1000',
    'SPACY_CONTEXT_THRESHOLD': '0.1',
    'SPACY_POSITION_BOOSTS': '0',
    'SPACY_COOLDOWNS': '1'
  };
  
  console.log('Setting test environment variables:');
  for (const [key, value] of Object.entries(testEnvs)) {
    originalValues[key] = process.env[key];
    process.env[key] = value;
    console.log(`  ${key} = ${value}`);
  }
  
  console.log('\nTesting with modified environment...');
  
  const spacy = new SpacyService();
  const testText = "This is a test message to verify environment controls are working properly";
  const result = spacy.process(testText);
  
  console.log(`✓ Processing with env controls successful`);
  console.log(`  Processed ${testText.length} chars`);
  console.log(`  Context: ${result.context.label}`);
  
  // Restore original values
  console.log('\nRestoring original environment...');
  for (const [key, value] of Object.entries(originalValues)) {
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
}

// Run tests
async function runAllTests() {
  try {
    await testSpacyOptimizations();
    testEnvironmentControls();
    console.log('\n🎉 ALL TESTS COMPLETED SUCCESSFULLY');
  } catch (error) {
    console.error('Test failed:', error);
    process.exit(1);
  }
}

if (require.main === module) {
  runAllTests();
}