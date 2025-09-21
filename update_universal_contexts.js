/**
 * Script to systematically add "general" context to universally applicable therapy advice
 */

const fs = require('fs');
const path = require('path');

// Load therapy advice
const therapyAdvicePath = path.join(__dirname, 'data/therapy_advice.json');
const therapyAdvice = JSON.parse(fs.readFileSync(therapyAdvicePath, 'utf8'));

console.log(`Processing ${therapyAdvice.length} therapy advice entries...`);

// Define universal communication skills that should have "general" context
const universalSkillIds = [
  // Communication fundamentals
  'TA008', 'TA015', 'TA022', 'TA032', 'TA035', 'TA036', 'TA043', 'TA049',
  
  // Emotional regulation techniques  
  'TA006', 'TA013', 'TA045',
  
  // Active listening and validation
  'TA011', 'TA026', 'TA051', 'TA055',
  
  // Self-awareness and mindfulness
  'TA018', 'TA030', 'TA048',
  
  // Boundary setting and needs communication
  'TA033', 'TA053',
  
  // De-escalation techniques (general applicability)
  'TA003', 'TA009', 'TA031', 'TA038', 'TA058'
];

let updatedCount = 0;

// Update suggestions to include "general" context
for (const item of therapyAdvice) {
  if (universalSkillIds.includes(item.id)) {
    if (Array.isArray(item.contexts) && item.contexts.includes('conflict') && !item.contexts.includes('general')) {
      item.contexts.push('general');
      updatedCount++;
      console.log(`Updated ${item.id}: "${item.advice.substring(0, 60)}..." - Added "general" context`);
    }
  }
}

// Write back to file
fs.writeFileSync(therapyAdvicePath, JSON.stringify(therapyAdvice, null, 2));

console.log(`\nBatch update completed: Updated ${updatedCount} suggestions with "general" context`);
console.log('These are universally applicable communication skills that work in many contexts.');

// Summary of what was updated
console.log('\nCategories updated:');
console.log('- Communication fundamentals (clarification, active listening, non-judgmental language)');
console.log('- Emotional regulation techniques (breathing, taking breaks, body awareness)');
console.log('- De-escalation techniques (lowering volume, slowing pace, acknowledging tension)');
console.log('- Boundary setting and needs communication');
console.log('- Self-awareness and mindfulness practices');