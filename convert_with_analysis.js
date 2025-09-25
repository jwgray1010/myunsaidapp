#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

async function convertToDualTriggerToneFromAnalysis() {
  const therapyAdvicePath = path.join(__dirname, 'data', 'therapy_advice.json');
  const analysisPath = path.join(__dirname, 'therapy_advice_dual_tone_analysis.json');
  
  console.log('Reading files...');
  const therapyData = JSON.parse(fs.readFileSync(therapyAdvicePath, 'utf8'));
  const analysisData = JSON.parse(fs.readFileSync(analysisPath, 'utf8'));
  
  console.log(`Therapy advice entries: ${therapyData.length}`);
  console.log(`Analysis entries: ${analysisData.results.length}`);
  
  // Create lookup map from analysis data
  const toneLookup = {};
  analysisData.results.forEach(result => {
    toneLookup[result.id] = {
      uiBucket: result.currentTone,
      rawTone: result.suggestedRawTone
    };
  });
  
  // Skip the last 500 entries that are already fixed
  const entriesToProcess = therapyData.length - 500;
  console.log(`Processing first ${entriesToProcess} entries (skipping last 500 already fixed)...`);
  
  let convertedCount = 0;
  let alreadyArrayCount = 0;
  let notFoundCount = 0;
  
  for (let i = 0; i < entriesToProcess; i++) {
    const entry = therapyData[i];
    
    // Skip if already an array
    if (Array.isArray(entry.triggerTone)) {
      alreadyArrayCount++;
      continue;
    }
    
    // Look up the dual tone suggestion
    const toneInfo = toneLookup[entry.id];
    if (!toneInfo) {
      console.log(`⚠️  No analysis found for ${entry.id}`);
      notFoundCount++;
      continue;
    }
    
    // Convert to array format using analysis data
    entry.triggerTone = [toneInfo.uiBucket, toneInfo.rawTone];
    convertedCount++;
    
    if (convertedCount % 100 === 0) {
      console.log(`Converted ${convertedCount} entries...`);
    }
  }
  
  console.log(`\nConversion complete!`);
  console.log(`- Converted: ${convertedCount} entries`);
  console.log(`- Already arrays: ${alreadyArrayCount} entries`);
  console.log(`- Not found in analysis: ${notFoundCount} entries`);
  console.log(`- Skipped last 500 entries (already fixed)`);
  console.log(`- Total entries: ${therapyData.length}`);
  
  // Write back to file
  console.log('\nWriting updated therapy_advice.json...');
  fs.writeFileSync(therapyAdvicePath, JSON.stringify(therapyData, null, 2), 'utf8');
  
  console.log('✅ Successfully updated therapy_advice.json');
  
  // Show a few examples of the conversion
  console.log('\n📋 Sample conversions:');
  for (let i = 0; i < Math.min(10, entriesToProcess); i++) {
    const entry = therapyData[i];
    if (Array.isArray(entry.triggerTone) && entry.triggerTone.length === 2) {
      console.log(`  ${entry.id}: triggerTone: ${JSON.stringify(entry.triggerTone)}`);
    }
  }
}

// Run the conversion
convertToDualTriggerToneFromAnalysis().catch(console.error);