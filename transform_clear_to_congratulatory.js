#!/usr/bin/env node

const fs = require('fs');

// Context-specific congratulatory templates that address the actual situation
const congratulatoryTemplates = {
  // Relationship contexts
  relationship_repair: [
    "Excellent work on relationship repair! You're actively investing in rebuilding trust and connection - this shows real emotional maturity.",
    "Beautiful approach to mending your relationship! Taking responsibility and following through demonstrates secure attachment behavior.",
    "This is wonderful relationship work! You're creating safety and stability that will strengthen your bond long-term.",
  ],
  
  conflict_prevention: [
    "Great job preventing conflict escalation! You're choosing connection over being right - this is exactly how secure communicators handle tension.",
    "Excellent conflict prevention! You're staying calm and solution-focused instead of getting defensive - this builds trust.",
    "Perfect de-escalation approach! You're prioritizing the relationship while addressing the issue - this is mature communication.",
  ],
  
  conflict_resolution: [
    "Outstanding conflict resolution! You're addressing issues directly while maintaining respect - this is how secure relationships work.",
    "Excellent job working through this conflict! You're staying focused on solutions rather than blame - this builds resilience.",
    "Beautiful conflict handling! You're creating space for both perspectives while moving toward resolution.",
  ],

  // Communication contexts  
  digital_communication: [
    "Great digital communication! You're being clear and thoughtful in your messages - this prevents misunderstandings.",
    "Excellent texting approach! You're staying connected while respecting boundaries - this is secure digital behavior.",
    "Perfect online communication! You're maintaining warmth and clarity in your messages - this builds digital trust.",
  ],
  
  positive_communication: [
    "Beautiful positive communication! You're actively building up your relationship through appreciation and encouragement.",
    "Excellent job spreading positivity! Your words are creating emotional safety and joy - this is how love grows.",
    "Wonderful positive energy! You're contributing to a supportive atmosphere that helps everyone thrive.",
  ],

  // Coordination contexts
  coordination: [
    "Great coordination skills! You're making logistics smooth and predictable - this reduces stress for everyone involved.",
    "Excellent organizational approach! You're creating clarity and follow-through that builds trust and reliability.",
    "Perfect coordination! You're balancing everyone's needs while keeping things moving forward efficiently.",
  ],
  
  group_communication: [
    "Outstanding group leadership! You're facilitating clear communication that includes everyone and reduces confusion.",
    "Excellent group dynamics! You're creating space for all voices while keeping conversations productive.",
    "Beautiful group facilitation! You're building consensus and clarity that helps the team succeed.",
  ],

  // Support contexts
  emotional_support: [
    "Beautiful emotional support! You're providing comfort and understanding while maintaining healthy boundaries.",
    "Excellent supportive communication! You're offering help in a way that empowers rather than enables.",
    "Wonderful caregiving approach! You're balancing compassion with sustainability - this is wise support.",
  ],
  
  support: [
    "Great supportive behavior! You're offering help that truly serves while taking care of your own needs too.",
    "Excellent support approach! You're being present and helpful without losing yourself in the process.",
    "Perfect balance of support! You're giving meaningfully while maintaining your own wellbeing.",
  ],

  // Personal development contexts
  personal_development: [
    "Excellent personal growth! You're developing self-awareness and emotional regulation - this benefits all your relationships.",
    "Beautiful self-development work! You're building skills that make you a better partner, friend, and family member.",
    "Great personal insight! You're understanding your patterns and choosing healthier responses - this is real progress.",
  ],
  
  self_protection: [
    "Excellent boundary setting! You're protecting your energy while staying connected - this is healthy self-care.",
    "Great self-advocacy! You're speaking up for your needs in a way that maintains relationships.",
    "Perfect self-protection! You're honoring your limits while keeping doors open for connection.",
  ],
  
  boundaries: [
    "Beautiful boundary work! You're being clear about your limits while staying kind and respectful.",
    "Excellent boundary communication! You're protecting yourself while maintaining care for others.",
    "Great boundary setting! You're creating healthy structure that benefits everyone involved.",
  ],

  // Work/practical contexts
  'work/school': [
    "Great professional communication! You're balancing productivity with relationship building in your workplace.",
    "Excellent academic/work approach! You're managing responsibilities while maintaining healthy connections.",
    "Perfect professional boundaries! You're being effective while keeping relationships positive.",
  ],
  
  co_parenting: [
    "Outstanding co-parenting communication! You're putting your children's needs first while working well with your co-parent.",
    "Excellent parenting partnership! You're creating stability and consistency that helps your kids thrive.",
    "Beautiful co-parenting approach! You're modeling healthy communication and cooperation for your children.",
  ],
  
  financial: [
    "Great financial communication! You're discussing money matters with clarity and respect - this builds trust.",
    "Excellent money conversations! You're being transparent and collaborative about finances.",
    "Perfect financial partnership! You're balancing individual needs with shared goals responsibly.",
  ],

  // Special situations
  dating: [
    "Excellent dating communication! You're being authentic while getting to know each other - this builds real connection.",
    "Great dating approach! You're balancing interest with boundaries as you explore compatibility.",
    "Beautiful dating communication! You're being genuine and respectful as you build this new connection.",
  ],
  
  safety: [
    "Excellent safety awareness! You're protecting yourself and others while maintaining connection where possible.",
    "Great safety communication! You're addressing concerns clearly and taking appropriate protective action.",
    "Perfect safety approach! You're balancing security with relationships in a mature way.",
  ],

  // Fallback for any other contexts
  general: [
    "Excellent secure communication! You're handling this situation with maturity and emotional intelligence.",
    "Great relationship skills! You're managing this challenge in a way that builds trust and connection.",
    "Beautiful communication approach! You're demonstrating the kind of secure behavior that strengthens relationships.",
  ]
};

// Attachment style specific praise additions
const attachmentPraise = {
  secure: "This kind of balanced, consistent communication is exactly what creates lasting, healthy relationships.",
  anxious: "You're managing your anxiety while staying connected - this shows real growth in secure behavior.",
  avoidant: "You're staying engaged instead of withdrawing - this is brave and relationship-building behavior.", 
  disorganized: "You're finding stability and consistency in your communication - this creates safety for everyone."
};

function getRandomTemplate(templates) {
  return templates[Math.floor(Math.random() * templates.length)];
}

function transformAdviceToCongratulatoryMessage(entry) {
  // Identify primary context for template selection
  const primaryContext = entry.contexts[0];
  const contextTemplates = congratulatoryTemplates[primaryContext] || congratulatoryTemplates.general;
  
  let congratulatoryMessage = getRandomTemplate(contextTemplates);
  
  // Add attachment-specific praise if applicable
  if (entry.attachmentStyles && entry.attachmentStyles.length > 0) {
    const primaryAttachment = entry.attachmentStyles[0];
    if (attachmentPraise[primaryAttachment]) {
      congratulatoryMessage += " " + attachmentPraise[primaryAttachment];
    }
  }
  
  return congratulatoryMessage;
}

function transformTherapyAdvice() {
  console.log('🔄 Loading therapy advice data...');
  
  // Read the current therapy advice
  const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));
  
  // Find all clear tone entries
  const clearEntries = data.filter(entry => entry.triggerTone === 'clear');
  console.log(`📊 Found ${clearEntries.length} clear tone entries to transform`);
  
  // Transform each clear entry to congratulatory
  let transformedCount = 0;
  const transformedData = data.map(entry => {
    if (entry.triggerTone === 'clear') {
      transformedCount++;
      
      return {
        ...entry,
        triggerTone: 'congratulatory', // Change tone
        advice: transformAdviceToCongratulatoryMessage(entry), // Transform message
        category: 'celebration', // Update category
        intent: ['celebrate', 'reinforce_secure_behavior'], // Update intent
        tags: [...(entry.tags || []), 'congratulatory', 'secure_communication'], // Add tags
      };
    }
    return entry;
  });
  
  console.log(`✅ Transformed ${transformedCount} entries to congratulatory messages`);
  
  // Write the transformed data
  fs.writeFileSync('data/therapy_advice_congratulatory.json', JSON.stringify(transformedData, null, 2));
  console.log('📝 Saved transformed advice to therapy_advice_congratulatory.json');
  
  // Show sample of transformations
  console.log('\n🎉 SAMPLE TRANSFORMATIONS:');
  console.log('=' * 50);
  
  const clearSample = clearEntries.slice(0, 5);
  const transformedSample = transformedData.filter(e => e.triggerTone === 'congratulatory').slice(0, 5);
  
  for (let i = 0; i < 5; i++) {
    console.log(`\n${i + 1}. Context: [${clearSample[i].contexts.join(', ')}]`);
    console.log(`   BEFORE: ${clearSample[i].advice}`);
    console.log(`   AFTER:  ${transformedSample[i].advice}`);
  }
  
  return transformedData;
}

// Run the transformation
if (require.main === module) {
  console.log('🚀 Starting Clear-to-Congratulatory Transformation');
  console.log('=' * 60);
  
  try {
    transformTherapyAdvice();
    console.log('\n🎊 Transformation Complete! All clear tone advice is now congratulatory.');
  } catch (error) {
    console.error('❌ Error during transformation:', error.message);
    process.exit(1);
  }
}