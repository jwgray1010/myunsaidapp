#!/usr/bin/env node

/**
 * Test: Complete Category Flow Pipeline
 * 
 * Tests the full pipeline from "I hate you" text:
 * 1. Tone analysis detects categories like "extreme-hostility" 
 * 2. Categories flow through tone.ts endpoint
 * 3. Categories reach suggestions.ts endpoint
 * 4. Categories are used for therapy advice boost matching
 */

console.log('🧪 Testing Complete Category Flow Pipeline\n');

const baseUrl = process.env.UNSAID_API_BASE_URL || 'http://localhost:3000';

async function testCategoryFlow() {
  try {
    console.log('1️⃣ Testing tone analysis with "I hate you"...');
    
    // Step 1: Test tone analysis endpoint 
    const toneResponse = await fetch(`${baseUrl}/api/v1/tone`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: 'I hate you',
        context: 'conflict'
      })
    });
    
    if (!toneResponse.ok) {
      console.error('❌ Tone analysis failed:', toneResponse.status);
      return;
    }
    
    const toneData = await toneResponse.json();
    console.log('✅ Tone analysis response:');
    console.log('   - Primary tone:', toneData.analysis?.primary_tone);
    console.log('   - UI tone:', toneData.ui_tone);
    console.log('   - Categories:', toneData.analysis?.categories || 'None detected');
    
    if (!toneData.analysis?.categories || toneData.analysis.categories.length === 0) {
      console.log('⚠️  No categories detected in tone analysis - check tone_patterns.json and toneAnalysis.ts');
      return;
    }
    
    console.log('\n2️⃣ Testing suggestions with tone analysis data...');
    
    // Step 2: Test suggestions endpoint with full tone analysis
    const suggestionsResponse = await fetch(`${baseUrl}/api/v1/suggestions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: 'I hate you',
        context: 'conflict',
        attachmentStyle: 'anxious',
        toneAnalysis: toneData // Pass the full tone analysis
      })
    });
    
    if (!suggestionsResponse.ok) {
      console.error('❌ Suggestions failed:', suggestionsResponse.status);
      return;
    }
    
    const suggestionsData = await suggestionsResponse.json();
    console.log('✅ Suggestions response:');
    console.log('   - Success:', suggestionsData.success);
    console.log('   - Suggestions count:', suggestionsData.suggestions?.length || 0);
    
    // Check if any suggestions have tone category boost debug info
    const boostedSuggestions = suggestionsData.suggestions?.filter(s => s.__tone_category_boost) || [];
    
    if (boostedSuggestions.length > 0) {
      console.log('   - Tone category boosts applied:', boostedSuggestions.length);
      boostedSuggestions.forEach((s, i) => {
        console.log(`     ${i+1}. Categories: ${s.__tone_category_boost.categories.join(', ')}`);
        console.log(`        Multiplier: ${s.__tone_category_boost.multiplier}`);
        console.log(`        Boost: +${s.__tone_category_boost.boost.toFixed(3)}`);
      });
    } else {
      console.log('   - No tone category boosts detected');
    }
    
    console.log('\n🎯 Category Flow Test Results:');
    console.log(`   - Categories detected: ${toneData.analysis?.categories?.length || 0}`);
    console.log(`   - Categories: ${(toneData.analysis?.categories || []).join(', ')}`);
    console.log(`   - Boosted suggestions: ${boostedSuggestions.length}`);
    console.log(`   - Pipeline status: ${boostedSuggestions.length > 0 ? '✅ WORKING' : '⚠️  PARTIAL'}`);
    
  } catch (error) {
    console.error('❌ Test failed:', error.message);
  }
}

testCategoryFlow();