#!/usr/bin/env node
/**
 * Simple Production API Debug Test
 * Minimal test to debug the production API issues
 */

const https = require('https');

async function makeRequest(url, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'Unsaid-Debug-Test/1.0'
      }
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          resolve({ status: res.statusCode, data: parsed, headers: res.headers });
        } catch (error) {
          resolve({ status: res.statusCode, data, error: error.message, headers: res.headers });
        }
      });
    });

    req.on('error', reject);
    req.write(JSON.stringify(body));
    req.end();
  });
}

async function debugToneAPI() {
  console.log('🔍 Debugging Production Tone API');
  console.log('================================\n');

  // Test 1: Legacy mode (simple payload)
  console.log('Test 1: Legacy mode (simple payload)');
  try {
    const response = await makeRequest('https://api.myunsaidapp.com/api/v1/tone', {
      text: "hello",
      client_seq: 1
    });
    
    console.log(`Status: ${response.status}`);
    console.log(`Response: ${JSON.stringify(response.data, null, 2)}`);
  } catch (error) {
    console.log(`Error: ${error.message}`);
  }

  console.log('\n' + '='.repeat(50) + '\n');

  // Test 2: Full mode (with doc_seq and text_hash)
  console.log('Test 2: Full mode (with doc_seq and text_hash)');
  try {
    const text = "I'm feeling frustrated with our communication";
    const crypto = require('crypto');
    const textHash = crypto.createHash('sha256').update(text).digest('hex');
    
    const response = await makeRequest('https://api.myunsaidapp.com/api/v1/tone', {
      text: text,
      doc_seq: 1,
      text_hash: textHash,
      user_id: "test_user_production"
    });
    
    console.log(`Status: ${response.status}`);
    console.log(`Response: ${JSON.stringify(response.data, null, 2)}`);
  } catch (error) {
    console.log(`Error: ${error.message}`);
  }

  console.log('\n' + '='.repeat(50) + '\n');

  // Test 3: Test suggestions API (general request)
  console.log('Test 3: Suggestions API (general request)');
  try {
    const response = await makeRequest('https://api.myunsaidapp.com/api/v1/suggestions', {
      text: "I need help with communication",
      limit: 5  // Request more suggestions
    });
    
    console.log(`Status: ${response.status}`);
    console.log(`Suggestions count: ${response.data.suggestions?.length || 0}`);
    
    if (response.data.suggestions && response.data.suggestions.length > 0) {
      console.log('\n🏆 All suggestions (ranked by score):');
      response.data.suggestions.forEach((suggestion, index) => {
        console.log(`${index + 1}. Score: ${suggestion.confidence?.toFixed(3) || 'N/A'}`);
        console.log(`   Text: "${suggestion.text}"`);
        console.log(`   Category: ${suggestion.category || 'N/A'}`);
        console.log(`   Reason: ${suggestion.reason || 'N/A'}`);
        if (suggestion.intents) {
          console.log(`   Intents: [${suggestion.intents.join(', ')}]`);
        }
        console.log('');
      });
      
      console.log(`UI tone: ${response.data.ui_tone}`);
      console.log(`Context: ${response.data.context}`);
      
      // Check if suggestions are properly ranked
      const scores = response.data.suggestions.map(s => s.confidence || 0);
      const isProperlyRanked = scores.every((score, i) => i === 0 || score <= scores[i-1]);
      console.log(`Properly ranked by score: ${isProperlyRanked ? '✅' : '❌'}`);
    }
  } catch (error) {
    console.log(`Error: ${error.message}`);
  }

  console.log('\n' + '='.repeat(50) + '\n');

  // Test 4: Test intent-aware suggestions (conflict scenario)
  console.log('Test 4: Intent-Aware Suggestions (conflict scenario)');
  try {
    const response = await makeRequest('https://api.myunsaidapp.com/api/v1/suggestions', {
      text: "I'm so frustrated and we keep fighting about everything",
      limit: 5  // Request more suggestions to see ranking
    });
    
    console.log(`Status: ${response.status}`);
    console.log(`Suggestions count: ${response.data.suggestions?.length || 0}`);
    
    if (response.data.suggestions && response.data.suggestions.length > 0) {
      console.log('\n🎯 Intent-aware suggestions for conflict:');
      response.data.suggestions.forEach((suggestion, index) => {
        console.log(`${index + 1}. Score: ${suggestion.confidence?.toFixed(3) || 'N/A'}`);
        console.log(`   Text: "${suggestion.text.slice(0, 80)}..."`);
        console.log(`   Category: ${suggestion.category || 'N/A'}`);
        console.log(`   Priority: ${suggestion.priority || 'N/A'}`);
        if (suggestion.intents) {
          console.log(`   Advice Intents: [${suggestion.intents.join(', ')}]`);
        }
        console.log('');
      });
      
      console.log(`Detected UI tone: ${response.data.ui_tone}`);
      console.log(`Detected context: ${response.data.context}`);
    }
  } catch (error) {
    console.log(`Error: ${error.message}`);
  }
}

debugToneAPI().catch(console.error);