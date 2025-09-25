// test-p-classification.js
// Test script for P-code classification system

const { classifyP, getAllPCodes } = require('./api/_lib/services/p-classifier.ts');
const { pickAdvice } = require('./api/_lib/services/advice-router.ts');

// Test cases for P-code classification
const testCases = [
  {
    text: "This thread is spinning—can we do a TL;DR and one question?",
    expectedPCodes: ["P031", "P044"],
    description: "Thread management + clarity check"
  },
  {
    text: "I hear you're feeling pressure about the deadline. That sounds really stressful.",
    expectedPCodes: ["P099"],
    description: "Validation and reflective listening"
  },
  {
    text: "I'm not available for a long call right now, but I can do one specific question.",
    expectedPCodes: ["P061"],
    description: "Boundary setting with concrete ask"
  },
  {
    text: "Let's pause here and revisit this when we've both cooled down.",
    expectedPCodes: ["P122"],
    description: "Safety and intensity control"
  },
  {
    text: "Can we check in by Friday and time-box this to 30 minutes?",
    expectedPCodes: ["P170"],
    description: "Expectations and planning"
  },
  {
    text: "I own my part in this misunderstanding. Thanks for bringing it up.",
    expectedPCodes: ["P217"],
    description: "Repair and recognition"
  },
  {
    text: "Let's scope this conversation - are we talking process or specific content?",
    expectedPCodes: ["P981"],
    description: "Context classification and lane labeling"
  },
  {
    text: "Quick assumption check - when you said 'later', did you mean today or this week?",
    expectedPCodes: ["P044"],
    description: "Assumption checking"
  },
  {
    text: "I appreciate you bringing this up. Let's set a quick check-in for tomorrow.",
    expectedPCodes: ["P217", "P170"],
    description: "Recognition + planning"
  },
  {
    text: "This feels too intense right now. Can we pause and come back in an hour?",
    expectedPCodes: ["P122", "P170"],
    description: "Safety control + time planning"
  }
];

async function runTests() {
  console.log('🧪 Testing P-Code Classification System\n');

  // Test 1: Get all available P-codes
  console.log('1. Available P-Codes:');
  const allPCodes = getAllPCodes();
  Object.entries(allPCodes).forEach(([code, description]) => {
    console.log(`   ${code}: ${description}`);
  });
  console.log('');

  // Test 2: Run classification tests
  console.log('2. Classification Tests:');
  let passed = 0;
  let total = testCases.length;

  for (const testCase of testCases) {
    console.log(`\n   Testing: "${testCase.text}"`);
    console.log(`   Expected: ${testCase.expectedPCodes.join(', ')}`);
    
    try {
      const result = await classifyP(testCase.text, { threshold: 0.3 });
      const foundPCodes = Object.keys(result.p_scores);
      
      console.log(`   Found: ${foundPCodes.join(', ') || 'none'}`);
      console.log(`   Scores: ${JSON.stringify(result.p_scores, null, 2)}`);
      
      // Check if at least one expected P-code was found
      const hasExpectedMatch = testCase.expectedPCodes.some(expected => 
        foundPCodes.includes(expected)
      );
      
      if (hasExpectedMatch) {
        console.log('   ✅ PASS');
        passed++;
      } else {
        console.log('   ❌ FAIL - No expected P-codes found');
      }
      
    } catch (error) {
      console.log(`   ❌ ERROR: ${error.message}`);
    }
  }

  console.log(`\n📊 Test Results: ${passed}/${total} passed (${Math.round(passed/total*100)}%)`);

  // Test 3: Advice routing integration (if therapy advice is available)
  console.log('\n3. Testing Advice Routing Integration:');
  
  try {
    // Sample therapy advice entries for testing
    const sampleAdvice = [
      {
        id: "TA_TEST_001",
        advice: "Test advice for thread management",
        triggerTone: ["alert", "frustrated"],
        contexts: ["conflict"],
        spacyLink: ["P031", "P044"],
        severityThreshold: { alert: 0.40 }
      },
      {
        id: "TA_TEST_002", 
        advice: "Test advice for validation",
        triggerTone: ["caution", "supportive"],
        contexts: ["repair"],
        spacyLink: ["P099", "P217"],
        severityThreshold: { caution: 0.35 }
      }
    ];

    const routingTest = await pickAdvice(
      "This thread is getting long. I hear you're frustrated - can we do a quick TLDR?",
      sampleAdvice,
      { tone: "alert", context: "conflict", includeScores: true }
    );

    console.log('   Routing Result:');
    console.log(`   P-Scores: ${JSON.stringify(routingTest.p_scores, null, 2)}`);
    console.log(`   Top Advice: ${routingTest.top.map(a => a.id).join(', ')}`);
    console.log(`   Total Candidates: ${routingTest.total_candidates}`);
    
    if (routingTest.top.length > 0) {
      console.log('   ✅ Advice routing working');
    } else {
      console.log('   ⚠️  No advice matched (may be expected with test data)');
    }

  } catch (error) {
    console.log(`   ❌ Routing test failed: ${error.message}`);
  }

  console.log('\n✨ P-Code Classification System Test Complete!');
}

// Run tests
runTests().catch(console.error);