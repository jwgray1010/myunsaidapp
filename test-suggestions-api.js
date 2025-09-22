#!/usr/bin/env node

/**
 * Comprehensive test for /api/v1/suggestions endpoint
 * Tests various communication scenarios and intent detection
 */

const https = require('https');
const crypto = require('crypto');

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

async function testSuggestions() {
    console.log('🧪 Testing /api/v1/suggestions endpoint...\n');

    const testCases = [
        {
            name: "Conflict de-escalation",
            input: {
                text: "We're fighting and I need help calming things down",
                doc_seq: 1,
                text_hash: crypto.createHash('sha256').update("We're fighting and I need help calming things down").digest('hex'),
                context: "conflict",
                attachment_style: "secure"
            },
            expectedIntents: ["deescalate", "interrupt_spiral"]
        },
        {
            name: "Seeking reassurance",
            input: {
                text: "I'm feeling insecure about us, I need to know you still care",
                doc_seq: 2,
                text_hash: crypto.createHash('sha256').update("I'm feeling insecure about us, I need to know you still care").digest('hex'),
                context: "relationship",
                attachment_style: "anxious"
            },
            expectedIntents: ["request_reassurance", "request_closeness"]
        },
        {
            name: "Setting boundaries",
            input: {
                text: "I need to establish some limits in our relationship",
                doc_seq: 3,
                text_hash: crypto.createHash('sha256').update("I need to establish some limits in our relationship").digest('hex'),
                context: "general",
                attachment_style: "secure"
            },
            expectedIntents: ["set_boundary", "protect_capacity"]
        },
        {
            name: "Expressing gratitude",
            input: {
                text: "Thank you for being so patient with me, I really appreciate you",
                doc_seq: 4,
                text_hash: crypto.createHash('sha256').update("Thank you for being so patient with me, I really appreciate you").digest('hex'),
                context: "general",
                attachment_style: "secure"
            },
            expectedIntents: ["express_gratitude", "request_closeness"]
        },
        {
            name: "Relationship anxiety",
            input: {
                text: "I'm worried that you don't love me anymore",
                doc_seq: 5,
                text_hash: crypto.createHash('sha256').update("I'm worried that you don't love me anymore").digest('hex'),
                context: "relationship",
                attachment_style: "anxious"
            },
            expectedIntents: ["request_reassurance", "express_vulnerability"]
        },
        {
            name: "Defensive response",
            input: {
                text: "That's not what I meant! You're misunderstanding me",
                doc_seq: 6,
                text_hash: crypto.createHash('sha256').update("That's not what I meant! You're misunderstanding me").digest('hex'),
                context: "conflict",
                attachment_style: "avoidant"
            },
            expectedIntents: ["clarify", "defend_self"]
        },
        {
            name: "Communication breakdown",
            input: {
                text: "We never talk anymore and I don't know how to fix this",
                doc_seq: 7,
                text_hash: crypto.createHash('sha256').update("We never talk anymore and I don't know how to fix this").digest('hex'),
                context: "relationship",
                attachment_style: "anxious"
            },
            expectedIntents: ["request_connection", "seek_solution"]
        },
        {
            name: "Feeling overwhelmed",
            input: {
                text: "I can't handle all this stress, I need space",
                doc_seq: 8,
                text_hash: crypto.createHash('sha256').update("I can't handle all this stress, I need space").digest('hex'),
                context: "general",
                attachment_style: "avoidant"
            },
            expectedIntents: ["set_boundary", "protect_capacity"]
        }
    ];

    let successCount = 0;

    for (const testCase of testCases) {
        console.log(`\n📝 Testing: ${testCase.name}`);
        console.log(`Input: "${testCase.input.text}"`);
        console.log(`Context: ${testCase.input.context}, Attachment: ${testCase.input.attachment_style}`);
        
        try {
            const result = await makeRequest('/api/v1/suggestions', testCase.input);
            
            if (result.statusCode === 200) {
                const responseData = result.data.data || result.data;
                const suggestions = responseData.suggestions || [];
                
                console.log(`✅ Status: ${result.statusCode}`);
                console.log(`📊 Suggestions returned: ${suggestions.length}`);
                
                if (suggestions.length > 0) {
                    console.log('\n🏆 Top suggestions:');
                    suggestions.slice(0, 3).forEach((suggestion, index) => {
                        console.log(`  ${index + 1}. Score: ${suggestion.score?.toFixed(3) || 'N/A'}`);
                        console.log(`     Text: "${suggestion.text?.substring(0, 80)}..."`);
                        console.log(`     Category: ${suggestion.category || 'N/A'}`);
                        if (suggestion.intents?.length > 0) {
                            console.log(`     Intents: [${suggestion.intents.join(', ')}]`);
                        }
                    });
                    
                    // Check if any expected intents are present
                    const allIntents = suggestions.flatMap(s => s.intents || []);
                    const matchedIntents = testCase.expectedIntents.filter(intent => 
                        allIntents.includes(intent)
                    );
                    
                    if (matchedIntents.length > 0) {
                        console.log(`🎯 Matched expected intents: [${matchedIntents.join(', ')}]`);
                        successCount++;
                    } else {
                        console.log(`⚠️ No expected intents found. Got: [${[...new Set(allIntents)].join(', ')}]`);
                    }
                } else {
                    console.log('⚠️ No suggestions returned');
                }
                
                // Show tone analysis if available
                if (responseData.ui_tone) {
                    console.log(`🎯 Detected tone: ${responseData.ui_tone}`);
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
    
    console.log(`\n📊 Suggestions API Results: ${successCount}/${testCases.length} tests had expected intents`);
}

async function testEdgeCases() {
    console.log('\n🔍 Testing suggestions edge cases...\n');

    const edgeCases = [
        {
            name: "Empty text",
            input: {
                text: "",
                doc_seq: 9,
                text_hash: crypto.createHash('sha256').update("").digest('hex')
            }
        },
        {
            name: "Very short text",
            input: {
                text: "Help",
                doc_seq: 10,
                text_hash: crypto.createHash('sha256').update("Help").digest('hex')
            }
        },
        {
            name: "Missing parameters (legacy mode)",
            input: {
                text: "This should work without doc_seq"
            }
        }
    ];

    for (const testCase of edgeCases) {
        console.log(`\n📝 Testing: ${testCase.name}`);
        console.log(`Input: "${testCase.input.text}"`);
        
        try {
            const result = await makeRequest('/api/v1/suggestions', testCase.input);
            
            console.log(`Status: ${result.statusCode}`);
            if (result.statusCode === 200) {
                const responseData = result.data.data || result.data;
                const suggestions = responseData.suggestions || [];
                console.log(`Suggestions: ${suggestions.length}`);
                if (suggestions.length > 0) {
                    console.log(`Top suggestion: "${suggestions[0].text?.substring(0, 60)}..."`);
                }
            } else {
                console.log(`Response: ${JSON.stringify(result.data).substring(0, 200)}...`);
            }
        } catch (error) {
            console.log(`Error: ${error.message}`);
        }
        
        console.log('─'.repeat(50));
    }
}

async function runTests() {
    console.log('🚀 Starting suggestions API comprehensive test...\n');
    
    await testSuggestions();
    await testEdgeCases();
    
    console.log('\n✅ Suggestions API testing complete!');
}

if (require.main === module) {
    runTests().catch(console.error);
}

module.exports = { testSuggestions, testEdgeCases };