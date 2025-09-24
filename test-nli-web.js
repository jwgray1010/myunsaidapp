#!/usr/bin/env node
/**
 * Quick test for web-based NLI implementation
 */

const path = require('path');

// Import the NLI service
const { NLILocalVerifier } = require('./api/_lib/services/nliLocal.ts');

async function testNLI() {
  console.log('🧪 Testing web-based NLI implementation...');

  const verifier = new NLILocalVerifier();

  try {
    // Initialize with web-based loading
    await verifier.init();

    if (!verifier.ready) {
      console.log('❌ NLI not ready - check initialization');
      return;
    }

    // Test a simple entailment
    const result = await verifier.score(
      "I love you",
      "I have positive feelings for you"
    );

    console.log('✅ NLI working!', result);
    console.log('Entailment score:', result.entail.toFixed(3));
    console.log('Contradiction score:', result.contra.toFixed(3));
    console.log('Neutral score:', result.neutral.toFixed(3));

  } catch (error) {
    console.error('❌ NLI test failed:', error.message);
  }
}

testNLI();