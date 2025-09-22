#!/usr/bin/env node

/**
 * Debug script to test context classification directly
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

async function debugContextClassification() {
    console.log('🔍 Debug: Context Classification\n');

    // Test with very explicit conflict words
    const testText = "You always argue and blame me for everything";
    
    console.log(`Testing text: "${testText}"`);
    console.log('Expected triggers: "you always", "argue", "blame"');
    console.log('Expected context: conflict\n');

    try {
        const result = await makeRequest('/api/v1/tone', {
            text: testText,
            doc_seq: 1,
            text_hash: crypto.createHash('sha256').update(testText).digest('hex'),
            include_explanation: true,
            include_context_analysis: true
        });
        
        if (result.statusCode === 200) {
            const responseData = result.data.data || result.data;
            
            console.log('📊 Tone Analysis Response:');
            console.log(`   Primary Tone: ${responseData.analysis?.primary_tone || 'N/A'}`);
            console.log(`   UI Tone: ${responseData.ui_tone || 'N/A'}`);
            console.log(`   Context: ${responseData.context || 'N/A'}`);
            
            if (responseData.analysis?.context_analysis) {
                console.log('\n🔍 Context Analysis Details:');
                console.log(`   Detected: ${JSON.stringify(responseData.analysis.context_analysis, null, 2)}`);
            }
            
            if (responseData.metadata?.feature_noticings) {
                console.log('\n📝 Feature Noticings:');
                responseData.metadata.feature_noticings.forEach(notice => {
                    console.log(`   - ${notice}`);
                });
            }
            
            if (responseData.metadata?.analysis_type) {
                console.log(`\n⚙️ Analysis Type: ${responseData.metadata.analysis_type}`);
            }
            
        } else {
            console.log(`❌ Error: ${result.statusCode}`);
            console.log(JSON.stringify(result.data, null, 2));
        }
    } catch (error) {
        console.log(`💥 Request failed: ${error.message}`);
    }
}

async function runDebug() {
    console.log('🚀 Starting context classification debug...\n');
    
    await debugContextClassification();
    
    console.log('\n✅ Debug complete!');
}

if (require.main === module) {
    runDebug().catch(console.error);
}

module.exports = { debugContextClassification };