// test-gcloud-integration.js
const { gcloudClient } = require('./api-backup/_lib/services/gcloudClient');

async function testGoogleCloudIntegration() {
  console.log('🧪 Testing Google Cloud integration...');
  
  try {
    // Test 1: Health check
    console.log('1️⃣ Testing health check...');
    const health = await gcloudClient.healthCheck();
    console.log('✅ Health check passed:', health);
    
    // Test 2: Simple tone analysis
    console.log('2️⃣ Testing tone analysis...');
    const toneResult = await gcloudClient.analyzeTone({
      text: "I'm really frustrated with this situation",
      context: 'general',
      userId: 'test-user',
      deepAnalysis: true,
      isNewUser: false,
      userProfile: {
        id: 'test-user',
        attachment: 'secure',
        windowComplete: true
      }
    });
    console.log('✅ Tone analysis passed:', {
      primary_tone: toneResult.primary_tone,
      confidence: toneResult.confidence,
      ui_tone: toneResult.ui_tone
    });
    
    // Test 3: Suggestions
    console.log('3️⃣ Testing suggestions...');
    const suggestionsResult = await gcloudClient.generateSuggestions({
      text: "I'm really frustrated with this situation",
      toneAnalysis: {
        classification: toneResult.primary_tone,
        confidence: toneResult.confidence,
        ui_distribution: toneResult.ui_distribution || { clear: 0.2, caution: 0.3, alert: 0.5 }
      },
      context: 'general',
      attachmentStyle: 'secure',
      userId: 'test-user'
    });
    console.log('✅ Suggestions passed:', {
      suggestionsCount: suggestionsResult?.suggestions?.length || 0,
      hasAlternatives: !!suggestionsResult?.alternatives
    });
    
    console.log('🎉 All Google Cloud integration tests passed!');
    
  } catch (error) {
    console.error('❌ Google Cloud integration test failed:', {
      error: error.message,
      stack: error.stack
    });
    process.exit(1);
  }
}

// Run the test
if (require.main === module) {
  testGoogleCloudIntegration();
}

module.exports = { testGoogleCloudIntegration };