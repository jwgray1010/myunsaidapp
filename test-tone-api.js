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
                mode: "legacy"
            }
        },
        {
            name: "Gratitude/appreciation test",
            input: {
                text: "Thanks so much for helping me today! I really appreciate it",
                mode: "legacy"
            }
        },
        {
            name: "Short appreciation",
            input: {
                text: "appreciate you 🙏",
                mode: "legacy"
            }
        },
        {
            name: "Frustrated message",
            input: {
                text: "I'm really frustrated that you never listen to me",
                mode: "legacy"
            }
        },
        {
            name: "Angry escalation",
            input: {
                text: "You always do this! You never consider my feelings and I'm sick of it!",
                mode: "legacy"
            }
        },
        {
            name: "Direct hate speech",
            input: {
                text: "i hate you!",
                mode: "legacy"
            }
        },
        {
            name: "Anxious/worried tone",
            input: {
                text: "I'm worried about us. Are we okay? I feel like we're drifting apart",
                mode: "legacy"
            }
        },
        {
            name: "Communication request",
            input: {
                text: "Can we talk about what happened earlier? I need to understand",
                mode: "legacy"
            }
        },
        {
            name: "Defensive response",
            input: {
                text: "That's not what I meant at all! You're twisting my words",
                mode: "legacy"
            }
        },
        {
            name: "Conflict escalation",
            input: {
                text: "Fine! If that's how you want to be, then I'm done trying",
                mode: "legacy"
            }
        },
        {
            name: "Relationship concern",
            input: {
                text: "I feel like we're not connecting anymore. What can we do?",
                mode: "legacy"
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
                console.log(`🎯 UI Tone: ${data.data?.ui_tone || data.ui_tone || 'N/A'}`);
                console.log(`📊 Primary Tone: ${data.data?.analysis?.primary_tone || data.analysis?.primary_tone || 'N/A'}`);
                console.log(`🎪 Confidence: ${data.data?.confidence || data.confidence || 'N/A'}`);
                console.log(`🎯 Context: ${data.data?.context || data.context || 'N/A'}`);
                
                const uiDist = data.data?.ui_distribution || data.ui_distribution;
                if (uiDist) {
                    console.log(`📈 Distribution: clear=${uiDist.clear?.toFixed(2)}, caution=${uiDist.caution?.toFixed(2)}, alert=${uiDist.alert?.toFixed(2)}`);
                }
                
                const clientSeq = data.data?.client_seq || data.client_seq;
                if (clientSeq) {
                    console.log(`🔢 Client Seq: ${clientSeq}`);
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
                mode: "legacy"
            }
        },
        {
            name: "Very short text",
            input: {
                text: "Ok",
                mode: "legacy"
            }
        },
        {
            name: "Long text",
            input: {
                text: "I've been thinking about this for a long time and I really need to tell you how I feel about everything that's been happening between us lately. I feel like we're not communicating well and I'm not sure what to do about it.",
                mode: "legacy"
            }
        },
        {
            name: "Special characters",
            input: {
                text: "Why can't you understand?! 😢💔 I'm trying my best...",
                mode: "legacy"
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