#!/usr/bin/env node

/**
 * Test script to verify NLI service works with transformers.js
 */

const { nliLocal } = require('./api/_lib/services/nliLocal.ts');

async function testNLI() {
    console.log('🧪 Testing NLI service with transformers.js...\n');

    try {
        // Initialize the NLI service
        console.log('Initializing NLI service...');
        await nliLocal.init();
        
        if (!nliLocal.ready) {
            console.log('⚠️ NLI service not ready, using rules-only fallback');
        } else {
            console.log('✅ NLI service ready with transformers.js');
        }

        // Test entailment scoring
        const premise = "I'm really frustrated with our communication lately.";
        const hypothesis = "The person is expressing frustration and needs emotional support.";
        
        console.log(`\n📝 Testing premise: "${premise}"`);
        console.log(`📋 Testing hypothesis: "${hypothesis}"`);
        
        const startTime = Date.now();
        const result = await nliLocal.score(premise, hypothesis);
        const duration = Date.now() - startTime;
        
        console.log(`\n📊 Results (${duration}ms):`);
        console.log(`  Entailment: ${(result.entail * 100).toFixed(1)}%`);
        console.log(`  Contradiction: ${(result.contra * 100).toFixed(1)}%`);
        console.log(`  Neutral: ${(result.neutral * 100).toFixed(1)}%`);
        
        // Test therapy advice fit
        const sampleAdvice = {
            id: 'test-advice',
            advice: 'It sounds like you need validation. Try saying "I feel frustrated when..."',
            intents: ['request_validation', 'expressing_frustration'],
            context: 'conflict'
        };
        
        console.log(`\n🎯 Testing advice fit for: "${premise}"`);
        const fitResult = await nliLocal.checkTherapyFit(premise, sampleAdvice);
        console.log(`  Fit Score: ${(fitResult.score * 100).toFixed(1)}%`);
        console.log(`  Method: ${fitResult.method}`);
        console.log(`  Appropriate: ${fitResult.appropriate ? '✅' : '❌'}`);
        
        console.log('\n✅ NLI service test completed successfully!');
        
    } catch (error) {
        console.error('\n❌ NLI service test failed:');
        console.error(error);
        process.exit(1);
    }
}

// Run the test
testNLI().catch(console.error);