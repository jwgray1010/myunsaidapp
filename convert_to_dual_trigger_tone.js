#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

async function convertToDualTriggerTone() {
  const therapyAdvicePath = path.join(__dirname, 'data', 'therapy_advice.json');
  
  console.log('Reading therapy_advice.json...');
  const data = JSON.parse(fs.readFileSync(therapyAdvicePath, 'utf8'));
  
  console.log(`Total entries: ${data.length}`);
  
  // Skip the last 500 entries that are already fixed
  const entriesToProcess = data.length - 500;
  console.log(`Processing first ${entriesToProcess} entries (skipping last 500 already fixed)...`);
  
  let convertedCount = 0;
  
  for (let i = 0; i < entriesToProcess; i++) {
    const entry = data[i];
    
    // Check if this entry has the old string format like "alert,angry"
    if (entry.triggerTone && typeof entry.triggerTone === 'string' && entry.triggerTone.includes(',')) {
      // Split the comma-separated string into array
      const tones = entry.triggerTone.split(',').map(tone => tone.trim());
      entry.triggerTone = tones;
      
      convertedCount++;
      
      if (convertedCount % 100 === 0) {
        console.log(`Converted ${convertedCount} entries...`);
      }
    }
    // Also handle case where there might be separate triggerTone and rawTone fields
    else if (entry.triggerTone && entry.rawTone) {
      const uiBucket = Array.isArray(entry.triggerTone) ? entry.triggerTone[0] : entry.triggerTone;
      const rawTone = entry.rawTone;
      
      // Create new triggerTone array
      entry.triggerTone = [uiBucket, rawTone];
      
      // Remove the old rawTone field
      delete entry.rawTone;
      
      convertedCount++;
      
      if (convertedCount % 100 === 0) {
        console.log(`Converted ${convertedCount} entries...`);
      }
    }
  }
  
  console.log(`\nConversion complete!`);
  console.log(`- Converted: ${convertedCount} entries`);
  console.log(`- Skipped last 500 entries (already fixed)`);
  console.log(`- Total entries: ${data.length}`);
  
  // Write back to file
  console.log('\nWriting updated therapy_advice.json...');
  fs.writeFileSync(therapyAdvicePath, JSON.stringify(data, null, 2), 'utf8');
  
  console.log('✅ Successfully updated therapy_advice.json');
  
  // Show a few examples of the conversion
  console.log('\n📋 Sample conversions:');
  for (let i = 0; i < Math.min(5, entriesToProcess); i++) {
    const entry = data[i];
    if (Array.isArray(entry.triggerTone) && entry.triggerTone.length === 2) {
      console.log(`  ${entry.id}: triggerTone: ${JSON.stringify(entry.triggerTone)}`);
    }
  }
}

// Run the conversion
convertToDualTriggerTone().catch(console.error);