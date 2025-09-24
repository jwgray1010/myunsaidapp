#!/usr/bin/env node

/**
 * Simple test to verify transformers.js works in the environment
 */

async function testTransformers() {
    console.log('🧪 Testing @xenova/transformers availability...\n');

    try {
        console.log('Loading transformers.js...');
        const { pipeline } = await import('@xenova/transformers');
        console.log('✅ Transformers.js loaded successfully');

        console.log('\n🔧 Creating zero-shot classification pipeline...');
        const classifier = await pipeline('zero-shot-classification', 'facebook/bart-large-mnli');
        console.log('✅ Pipeline created successfully');

        // Test classification
        const sequence = "I'm really frustrated with our communication lately.";
        const candidateLabels = ['contradiction', 'neutral', 'entailment'];

        console.log(`\n📝 Testing sequence: "${sequence}"`);
        console.log(`📋 Candidate labels: ${candidateLabels.join(', ')}`);

        const startTime = Date.now();
        const result = await classifier(sequence, candidateLabels);
        const duration = Date.now() - startTime;

        console.log(`\n📊 Results (${duration}ms):`);
        result.labels.forEach((label, i) => {
            console.log(`  ${label}: ${(result.scores[i] * 100).toFixed(1)}%`);
        });

        console.log('\n✅ Transformers.js test completed successfully!');
        console.log('\n🎯 NLI service should work with the fixed code.');

    } catch (error) {
        console.error('\n❌ Transformers.js test failed:');
        console.error(error.message);
        
        if (error.message.includes('Cannot find module')) {
            console.error('\n💡 Try: npm install @xenova/transformers');
        }
        
        process.exit(1);
    }
}

// Run the test
testTransformers().catch(console.error);