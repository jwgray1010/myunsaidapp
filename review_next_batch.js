/**
 * Script to add "general" context to the next batch of therapy advice (TA061-TA120)
 */

const fs = require('fs');
const path = require('path');

// Load therapy advice
const therapyAdvicePath = path.join(__dirname, 'data/therapy_advice.json');
const therapyAdvice = JSON.parse(fs.readFileSync(therapyAdvicePath, 'utf8'));

console.log(`Processing therapy advice entries TA061-TA120...`);

// Check what's in this range first
const targetRange = therapyAdvice.filter(item => {
  const idNum = parseInt(item.id.replace('TA', ''));
  return idNum >= 61 && idNum <= 120;
});

console.log(`Found ${targetRange.length} entries in TA061-TA120 range`);

// Display them for review
targetRange.forEach(item => {
  console.log(`${item.id}: "${item.advice.substring(0, 70)}..." [${item.contexts.join(', ')}]`);
});

// Look for more universal skills in this range
const moreUniversalSkills = [
  // Additional communication and emotional regulation techniques
  // We'll identify these after reviewing the output above
];

let updatedCount = 0;

// Update suggestions to include "general" context
for (const item of therapyAdvice) {
  if (moreUniversalSkills.includes(item.id)) {
    if (Array.isArray(item.contexts) && item.contexts.includes('conflict') && !item.contexts.includes('general')) {
      item.contexts.push('general');
      updatedCount++;
      console.log(`Updated ${item.id}: Added "general" context`);
    }
  }
}

console.log(`\nBatch 2 preparation completed. Found ${targetRange.length} entries to review for universal applicability.`);