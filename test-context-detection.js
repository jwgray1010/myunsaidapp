#!/usr/bin/env node

/**
 * Test suggestions API with ACTUAL context trigger words
 * Based on the context_classifier.json patterns
 */

const https = require('https');
const crypto = require('crypto');

function makeRequest(endpoint, data) {
    return new Promise((resolve, reject) => {
        const postData = JSON.stringify(data);
        
        const options = {
            hostname: 'api.myunsaidapp.com',
            port: 443,
            path: endpoint,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(postData)
            }
        };

        const req = https.request(options, (res) => {
            let body = '';
            res.on('data', (chunk) => {
                body += chunk;
            });
            
            res.on('end', () => {
                try {
                    const result = JSON.parse(body);
                    resolve({ statusCode: res.statusCode, data: result });
                } catch (e) {
                    resolve({ statusCode: res.statusCode, data: body });
                }
            });
        });

        req.on('error', (e) => {
            reject(e);
        });

        req.write(postData);
        req.end();
    });
}

async function testContextDetection() {
    console.log('🎯 Testing Context Detection with Proper Trigger Words\n');

    const testCases = [
        {
            name: "CONFLICT context (trigger: 'argue', 'you always')",
            input: {
                text: "You always argue with me and never listen",
                doc_seq: 1,
                text_hash: crypto.createHash('sha256').update("You always argue with me and never listen").digest('hex'),
                attachment_style: "anxious"
            },
            expectedContext: "conflict"
        },
        {
            name: "CONFLICT context (trigger: 'fight', 'blame')",
            input: {
                text: "We fight all the time and you blame me for everything",
                doc_seq: 2,
                text_hash: crypto.createHash('sha256').update("We fight all the time and you blame me for everything").digest('hex'),
                attachment_style: "secure"
            },
            expectedContext: "conflict"
        },
        {
            name: "RELATIONSHIP context (trigger: 'our relationship', 'us')",
            input: {
                text: "I'm worried about our relationship and how we are doing",
                doc_seq: 3,
                text_hash: crypto.createHash('sha256').update("I'm worried about our relationship and how we are doing").digest('hex'),
                attachment_style: "anxious"
            },
            expectedContext: "relationship"
        },
        {
            name: "COPARENT context (trigger: 'kids', 'parenting')",
            input: {
                text: "We need to discuss our parenting approach with the kids",
                doc_seq: 4,
                text_hash: crypto.createHash('sha256').update("We need to discuss our parenting approach with the kids").digest('hex'),
                attachment_style: "secure"
            },
            expectedContext: "coparent"
        },
        {
            name: "REPAIR context (trigger: 'sorry', 'apologize')",
            input: {
                text: "I'm sorry about earlier, I want to apologize",
                doc_seq: 5,
                text_hash: crypto.createHash('sha256').update("I'm sorry about earlier, I want to apologize").digest('hex'),
                attachment_style: "secure"
            },
            expectedContext: "repair"
        }
    ];

    let successCount = 0;

    for (const testCase of testCases) {
        console.log(`\n📝 Testing: ${testCase.name}`);
        console.log(`Input: "${testCase.input.text}"`);
        console.log(`Expected Context: ${testCase.expectedContext}`);
        
        try {
            const result = await makeRequest('/api/v1/suggestions', testCase.input);
            
            if (result.statusCode === 200) {
                const responseData = result.data.data || result.data;
                const suggestions = responseData.suggestions || [];
                const detectedContext = responseData.context || 'general';
                const detectedTone = responseData.ui_tone || 'unknown';
                
                console.log(`✅ Status: ${result.statusCode}`);
                console.log(`🎯 Detected Context: ${detectedContext}`);
                console.log(`🎨 Detected Tone: ${detectedTone}`);
                console.log(`📊 Suggestions: ${suggestions.length}`);
                
                if (suggestions.length > 0) {
                    console.log(`\n🏆 Top suggestion:`);
                    const top = suggestions[0];
                    console.log(`   Text: "${top.text?.substring(0, 80)}..."`);
                    console.log(`   Score: ${top.score?.toFixed(3) || 'N/A'}`);
                    console.log(`   Category: ${top.category || 'N/A'}`);
                    if (top.intents?.length > 0) {
                        console.log(`   Intents: [${top.intents.join(', ')}]`);
                    }
                    if (top.triggerTone) {
                        console.log(`   Trigger Tone: ${top.triggerTone}`);
                    }
                    if (top.contexts?.length > 0) {
                        console.log(`   Contexts: [${top.contexts.join(', ')}]`);
                    }
                }
                
                // Check if context matches expectation
                if (detectedContext === testCase.expectedContext) {
                    console.log(`🎯 ✅ Context detection SUCCESS!`);
                    successCount++;
                } else {
                    console.log(`🎯 ❌ Context mismatch. Expected: ${testCase.expectedContext}, Got: ${detectedContext}`);
                }
                
            } else {
                console.log(`❌ Status: ${result.statusCode}`);
                console.log(`Error: ${JSON.stringify(result.data, null, 2)}`);
            }
        } catch (error) {
            console.log(`💥 Request failed: ${error.message}`);
        }
        
        console.log('─'.repeat(70));
        
        // Brief pause between requests
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
    
    console.log(`\n📊 Context Detection Results: ${successCount}/${testCases.length} correctly detected contexts`);
    
    if (successCount === testCases.length) {
        console.log('🎉 Perfect! Context detection is working correctly!');
    } else {
        console.log('ℹ️  Some contexts fell back to "general" - this might be expected for edge cases');
    }
}

async function runTests() {
    console.log('🚀 Testing Context-Aware Suggestions API...\n');
    
    await testContextDetection();
    
    console.log('\n✅ Context detection testing complete!');
}

if (require.main === module) {
    runTests().catch(console.error);
}

module.exports = { testContextDetection };