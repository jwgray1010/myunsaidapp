#!/usr/bin/env node

/**
 * Test script for /api/v1/tone endpoint
 * Tests tone analysis with various input scenarios
 */

const https = require('https');

const API_BASE = 'https://api.myunsaidapp.com';

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

async function testToneAnalysis() {
    console.log('🧪 Testing /api/v1/tone endpoint...\n');

    const testCases = [
        {
            name: "Basic positive message",
            input: {
                text: "I love you and appreciate everything you do",
                doc_seq: 1,
                text_hash: "hash1"
            }
        },
        {
            name: "Frustrated message",
            input: {
                text: "I'm really frustrated that you never listen to me",
                doc_seq: 2,
                text_hash: "hash2"
            }
        },
        {
            name: "Angry escalation",
            input: {
                text: "You always do this! You never consider my feelings and I'm sick of it!",
                doc_seq: 3,
                text_hash: "hash3"
            }
        },
        {
            name: "Anxious/worried tone",
            input: {
                text: "I'm worried about us. Are we okay? I feel like we're drifting apart",
                doc_seq: 4,
                text_hash: "hash4"
            }
        },
        {
            name: "Communication request",
            input: {
                text: "Can we talk about what happened earlier? I need to understand",
                doc_seq: 5,
                text_hash: "hash5"
            }
        },
        {
            name: "Defensive response",
            input: {
                text: "That's not what I meant at all! You're twisting my words",
                doc_seq: 6,
                text_hash: "hash6"
            }
        },
        {
            name: "Conflict escalation",
            input: {
                text: "Fine! If that's how you want to be, then I'm done trying",
                doc_seq: 7,
                text_hash: "hash7"
            }
        },
        {
            name: "Relationship concern",
            input: {
                text: "I feel like we're not connecting anymore. What can we do?",
                doc_seq: 8,
                text_hash: "hash8"
            }
        }
    ];

    for (const testCase of testCases) {
        console.log(`\n📝 Testing: ${testCase.name}`);
        console.log(`Input: "${testCase.input.text}"`);
        
        try {
            const result = await makeRequest('/api/v1/tone', testCase.input);
            
            if (result.statusCode === 200) {
                const { data } = result;
                console.log(`✅ Status: ${result.statusCode}`);
                console.log(`🎯 UI Tone: ${data.ui_tone || 'N/A'}`);
                console.log(`📊 Primary Tone: ${data.analysis?.primary_tone || 'N/A'}`);
                console.log(`🎪 Confidence: ${data.analysis?.confidence || 'N/A'}`);
                
                if (data.ui_distribution) {
                    console.log(`📈 Distribution: clear=${data.ui_distribution.clear}, caution=${data.ui_distribution.caution}, alert=${data.ui_distribution.alert}`);
                }
                
                if (data.client_seq) {
                    console.log(`🔢 Client Seq: ${data.client_seq}`);
                }
            } else {
                console.log(`❌ Status: ${result.statusCode}`);
                console.log(`Error: ${JSON.stringify(result.data, null, 2)}`);
            }
        } catch (error) {
            console.log(`💥 Request failed: ${error.message}`);
        }
        
        console.log('─'.repeat(60));
    }
}

async function testEdgeCases() {
    console.log('\n🔍 Testing edge cases...\n');

    const edgeCases = [
        {
            name: "Empty text",
            input: {
                text: "",
                doc_seq: 9,
                text_hash: "hash9"
            }
        },
        {
            name: "Very short text",
            input: {
                text: "Ok",
                doc_seq: 10,
                text_hash: "hash10"
            }
        },
        {
            name: "Long text",
            input: {
                text: "I've been thinking about this for a long time and I really need to tell you how I feel about everything that's been happening between us lately. I feel like we're not communicating well and I'm not sure what to do about it.",
                doc_seq: 11,
                text_hash: "hash11"
            }
        },
        {
            name: "Special characters",
            input: {
                text: "Why can't you understand?! 😢💔 I'm trying my best...",
                doc_seq: 12,
                text_hash: "hash12"
            }
        },
        {
            name: "Missing doc_seq (legacy mode)",
            input: {
                text: "This should fail without doc_seq"
            }
        }
    ];

    for (const testCase of edgeCases) {
        console.log(`\n📝 Testing: ${testCase.name}`);
        console.log(`Input: "${testCase.input.text}"`);
        
        try {
            const result = await makeRequest('/api/v1/tone', testCase.input);
            
            if (result.statusCode === 200) {
                const { data } = result;
                console.log(`✅ Status: ${result.statusCode}`);
                console.log(`🎯 UI Tone: ${data.ui_tone || 'N/A'}`);
                console.log(`📊 Primary Tone: ${data.analysis?.primary_tone || 'N/A'}`);
            } else {
                console.log(`⚠️ Status: ${result.statusCode}`);
                console.log(`Response: ${JSON.stringify(result.data, null, 2)}`);
            }
        } catch (error) {
            console.log(`💥 Request failed: ${error.message}`);
        }
        
        console.log('─'.repeat(60));
    }
}

async function runTests() {
    console.log('🚀 Starting tone analysis API tests...\n');
    
    await testToneAnalysis();
    await testEdgeCases();
    
    console.log('\n✅ Tone API testing complete!');
}

if (require.main === module) {
    runTests().catch(console.error);
}

module.exports = { testToneAnalysis, testEdgeCases };