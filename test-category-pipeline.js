#!/usr/bin/env node

// Test category pipeline from tone analysis to therapy advice boost
// This test verifies categories flow from tone patterns through to suggestions

const fetch = require('node-fetch');

async function testCategoryPipeline() {
  console.log('🧪 Testing Category Pipeline from Tone Analysis to Therapy Advice Boost\n');
  
  const testCases = [
    {
      name: 'Extreme Hostility Text',
      text: 'I hate you so much, you are absolutely terrible and stupid',
      expectedCategories: ['extreme-hostility'], // Should match tone_patterns.json categories
      description: 'Text with extreme hostility pattern should detect category and boost matching therapy advice'
    },
    {
      name: 'Blame Pattern',
      text: 'You always mess things up and never listen to me',
      expectedCategories: ['blame'], // Should match tone_patterns.json categories  
      description: 'Text with blame pattern should detect category and boost matching therapy advice'
    },
    {
      name: 'Repair Language',
      text: 'I apologize for my words earlier, can we work this out together?',
      expectedCategories: ['repair'], // Should match tone_patterns.json categories
      description: 'Text with repair language should detect category and boost matching therapy advice'
    }
  ];

  for (const testCase of testCases) {
    console.log(`\n📝 Testing: ${testCase.name}`);
    console.log(`   Text: "${testCase.text}"`);
    console.log(`   Expected Categories: ${testCase.expectedCategories.join(', ')}`);
    
    try {
      // Step 1: Test tone analysis endpoint
      console.log('\n1️⃣ Testing Tone Analysis Endpoint...');
      const toneResponse = await fetch('http://localhost:3000/api/v1/tone', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-user-id': 'test-user-categories'
        },
        body: JSON.stringify({
          text: testCase.text,
          context: 'general'
        })
      });
      
      if (!toneResponse.ok) {
        console.log(`❌ Tone API failed: ${toneResponse.status} ${toneResponse.statusText}`);
        continue;
      }
      
      const toneData = await toneResponse.json();
      console.log(`   ✅ Tone detected: ${toneData.tone}`);
      console.log(`   ✅ UI tone: ${toneData.ui_tone}`);
      console.log(`   ✅ Categories: ${JSON.stringify(toneData.categories || [])}`);
      
      // Verify categories are present
      const detectedCategories = toneData.categories || [];
      const hasExpectedCategory = testCase.expectedCategories.some(expected => 
        detectedCategories.includes(expected)
      );
      
      if (hasExpectedCategory) {
        console.log(`   ✅ Expected category detected successfully`);
      } else {
        console.log(`   ⚠️  Expected categories not detected. Got: ${detectedCategories.join(', ')}`);
      }

      // Step 2: Test suggestions endpoint with same text
      console.log('\n2️⃣ Testing Suggestions Endpoint...');
      const suggestionsResponse = await fetch('http://localhost:3000/api/v1/suggestions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-user-id': 'test-user-categories'
        },
        body: JSON.stringify({
          text: testCase.text,
          context: 'general',
          maxSuggestions: 5
        })
      });
      
      if (!suggestionsResponse.ok) {
        console.log(`❌ Suggestions API failed: ${suggestionsResponse.status} ${suggestionsResponse.statusText}`);
        continue;
      }
      
      const suggestionsData = await suggestionsResponse.json();
      console.log(`   ✅ Received ${suggestionsData.suggestions?.length || 0} suggestions`);
      
      if (suggestionsData.suggestions && suggestionsData.suggestions.length > 0) {
        // Show top suggestion and check if it has category boost
        const topSuggestion = suggestionsData.suggestions[0];
        console.log(`   ✅ Top suggestion: "${topSuggestion.advice?.substring(0, 60)}..."`);
        console.log(`   ✅ Suggestion categories: ${JSON.stringify(topSuggestion.categories || [])}`);
        console.log(`   ✅ LTR Score: ${topSuggestion.ltrScore}`);
        
        // Check if any suggestions have categories that match detected tone categories
        const matchingSuggestions = suggestionsData.suggestions.filter(s => 
          s.categories && s.categories.some(cat => detectedCategories.includes(cat))
        );
        
        if (matchingSuggestions.length > 0) {
          console.log(`   ✅ Found ${matchingSuggestions.length} suggestions with matching categories - category boost working!`);
        } else {
          console.log(`   ⚠️  No suggestions found with matching categories`);
        }
      }
      
    } catch (error) {
      console.log(`❌ Test failed: ${error.message}`);
    }
    
    console.log('\n' + '─'.repeat(80));
  }
  
  console.log('\n🎉 Category Pipeline Test Complete!');
  console.log('\nNext steps:');
  console.log('1. Check tone analysis logs for category detection');
  console.log('2. Check suggestions logs for category boost application');
  console.log('3. Verify therapy advice entries have correct boostSources');
}

// Run the test
if (require.main === module) {
  testCategoryPipeline().catch(console.error);
}

module.exports = { testCategoryPipeline };