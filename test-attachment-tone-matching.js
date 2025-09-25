#!/usr/bin/env node

// Test attachment-aware tone matching system
const fs = require('fs');
const path = require('path');

// Load tone bucket mapping with attachment overrides
function loadToneBucketMapping() {
    try {
        const mappingPath = path.join(__dirname, 'data', 'tone_bucket_mapping.json');
        const mapping = JSON.parse(fs.readFileSync(mappingPath, 'utf8'));
        return mapping;
    } catch (error) {
        console.error('Error loading tone bucket mapping:', error);
        return null;
    }
}

// Simulate the attachment-aware UI bucket logic from suggestions.ts
function getUIBucketForToneWithAttachment(toneKey, attachmentStyle, mapping, debug = false) {
    const entry = mapping?.toneBuckets?.[toneKey];
    if (!entry || !entry.base) return null;
    
    // Start with base distribution
    let dist = { ...entry.base };
    
    if (debug) {
        console.log(`    Base: clear=${dist.clear}, caution=${dist.caution}, alert=${dist.alert}`);
    }
    
    // Apply attachment-specific overrides (these are DELTAS, not absolute values)
    if (attachmentStyle && mapping.attachmentOverrides?.[attachmentStyle]) {
        const overrides = mapping.attachmentOverrides[attachmentStyle];
        if (overrides[toneKey]) {
            // Apply the specific override deltas for this tone and attachment style
            const override = overrides[toneKey];
            if (debug) {
                console.log(`    Override deltas: ${JSON.stringify(override)}`);
            }
            
            Object.keys(override).forEach(bucket => {
                if (['clear', 'caution', 'alert'].includes(bucket)) {
                    // Add the delta to the base value
                    const oldValue = dist[bucket] || 0;
                    dist[bucket] = oldValue + Number(override[bucket]);
                    // Ensure no negative probabilities
                    dist[bucket] = Math.max(0, dist[bucket]);
                    if (debug) {
                        console.log(`      ${bucket}: ${oldValue} + ${override[bucket]} = ${oldValue + Number(override[bucket])} → ${dist[bucket]}`);
                    }
                }
            });
            
            if (debug) {
                console.log(`    After deltas: clear=${dist.clear}, caution=${dist.caution}, alert=${dist.alert}`);
            }
            
            // Renormalize after applying deltas
            const total = (dist.clear || 0) + (dist.caution || 0) + (dist.alert || 0);
            if (total > 0) {
                dist.clear = (dist.clear || 0) / total;
                dist.caution = (dist.caution || 0) / total;
                dist.alert = (dist.alert || 0) / total;
            }
            
            if (debug) {
                console.log(`    After normalize: clear=${dist.clear?.toFixed(3)}, caution=${dist.caution?.toFixed(3)}, alert=${dist.alert?.toFixed(3)}`);
            }
        }
    }
    
    // Return the bucket with highest probability
    const buckets = ['clear', 'caution', 'alert'];
    let maxBucket = 'clear';
    let maxValue = 0;
    
    for (const bucket of buckets) {
        const value = Number(dist[bucket]) || 0;
        if (value > maxValue) {
            maxValue = value;
            maxBucket = bucket;
        }
    }
    
    if (debug) {
        console.log(`    Winner: ${maxBucket} (${(maxValue).toFixed(3)})`);
    }
    
    return maxBucket;
}

// Test cases based on user requirements
function runTests() {
    console.log('🧪 Testing Attachment-Aware Tone Mapping\n');
    
    const mapping = loadToneBucketMapping();
    if (!mapping) {
        console.error('Failed to load tone bucket mapping');
        return;
    }
    
    const testCases = [
        // Withdrawn tone - should vary by attachment style
        {
            tone: 'withdrawn',
            avoidant: 'alert',    // "for an avoidant, withdrawn is alert"
            anxious: 'caution',   // "for an anxious person....it could be just caution"
            secure: 'caution',    // baseline
            disorganized: 'alert' // heightened sensitivity
        },
        // Apologetic tone - should vary by attachment style  
        {
            tone: 'apologetic',
            avoidant: 'clear',    // minimization of emotional distress
            anxious: 'caution',   // heightened concern about relationships
            secure: 'caution',    // baseline
            disorganized: 'caution' // baseline
        },
        // Assertive tone - should be caution for controlling language
        {
            tone: 'assertive',
            avoidant: 'caution',  // baseline after controlling language update
            anxious: 'caution',   // baseline
            secure: 'clear',      // healthy assertiveness
            disorganized: 'caution' // baseline
        },
        // Anxious tone - should escalate for avoidant
        {
            tone: 'anxious',
            avoidant: 'alert',    // emotional distress escalation
            anxious: 'caution',   // baseline
            secure: 'caution',    // baseline
            disorganized: 'alert' // heightened sensitivity
        }
    ];
    
    console.log('Testing attachment-specific tone bucket mappings:\n');
    
    testCases.forEach((testCase, index) => {
        console.log(`Test ${index + 1}: "${testCase.tone}" tone`);
        console.log('-------------------------------------------');
        
        const attachmentStyles = ['avoidant', 'anxious', 'secure', 'disorganized'];
        
        attachmentStyles.forEach(style => {
            const debug = (testCase.tone === 'withdrawn' && (style === 'avoidant' || style === 'disorganized')) || 
                         (testCase.tone === 'assertive' && style === 'anxious') ||
                         (testCase.tone === 'anxious' && (style === 'avoidant' || style === 'disorganized'));
            
            if (debug) {
                console.log(`  Debugging ${style} ${testCase.tone}:`);
            }
            
            const actualBucket = getUIBucketForToneWithAttachment(testCase.tone, style, mapping, debug);
            const expectedBucket = testCase[style];
            const status = actualBucket === expectedBucket ? '✅' : '❌';
            
            console.log(`${style.padEnd(12)}: ${actualBucket.padEnd(8)} ${status} (expected: ${expectedBucket})`);
            
            if (actualBucket !== expectedBucket) {
                console.log(`  ⚠️  MISMATCH for ${style} attachment with ${testCase.tone} tone`);
            }
        });
        console.log('');
    });
    
    // Test base tone distributions without attachment overrides
    console.log('\nTesting base tone distributions (no attachment overrides):');
    console.log('--------------------------------------------------------');
    
    const testTones = ['supportive', 'hostile', 'overwhelmed', 'contempt'];
    testTones.forEach(tone => {
        const bucket = getUIBucketForToneWithAttachment(tone, null, mapping);
        console.log(`${tone.padEnd(15)}: ${bucket}`);
    });
}

// Run the tests
if (require.main === module) {
    runTests();
}

module.exports = {
    loadToneBucketMapping,
    getUIBucketForToneWithAttachment,
    runTests
};