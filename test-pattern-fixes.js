// Quick test for tone pattern fixes
const testCases = [
  { text: "You always do this.", expected: "alert", type: "escalation" },
  { text: "Watch your back.", expected: "alert", type: "threat" },
  { text: "Let's pause and take a deep breath.", expected: "clear", type: "emotional_regulation" },
  { text: "Are you safe right now?", expected: "clear", type: "safety_check" },
  { text: "You don't care about me.", expected: "caution", type: "attachment_triggers" }
];

console.log('🧪 Testing tone pattern fixes...');

// Test the buildRegex function
function buildRegex(pattern) {
  let flags = 'u';
  let src = pattern;

  if (src.startsWith('(?i)')) {
    src = src.slice(4);
    flags += 'i';
  }

  try {
    return new RegExp(src, flags);
  } catch (error) {
    console.log(`❌ Failed to compile: ${pattern}`, error.message);
    throw error;
  }
}

// Test PCRE-style patterns
const testPatterns = [
  "(?i)\\byou\\s+(always|never|constantly|every\\s*time)\\b",
  "(?i)\\bwatch\\s+your\\s+back\\b",
  "\\blet'?s\\s+(pause|take\\s+a\\s+deep\\s+breath)\\b"
];

console.log('\n📋 Testing regex compilation:');
for (const pattern of testPatterns) {
  try {
    const regex = buildRegex(pattern);
    console.log(`✅ Compiled: ${pattern} → /${regex.source}/${regex.flags}`);
    
    // Test against sample text
    if (pattern.includes('always')) {
      const match = regex.test("You always do this.");
      console.log(`   Test "You always do this.": ${match ? '✅ MATCH' : '❌ NO MATCH'}`);
    }
  } catch (error) {
    console.log(`❌ Failed: ${pattern}`);
  }
}

console.log('\n🎯 Acceptance test results:');
for (const testCase of testCases) {
  console.log(`Text: "${testCase.text}"`);
  console.log(`Expected: ${testCase.expected} (${testCase.type})`);
  console.log(`Status: ⏳ (requires full API test)`);
  console.log('---');
}

console.log('\n✅ Regex compilation fixes complete!');
console.log('Next: Deploy and test with full API to verify pattern matching');