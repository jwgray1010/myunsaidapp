#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

function extractIdAndRawTone() {
  const analysisPath = path.join(__dirname, 'therapy_advice_dual_tone_analysis.json');
  
  console.log('Reading dual tone analysis file...');
  const analysisData = JSON.parse(fs.readFileSync(analysisPath, 'utf8'));
  
  console.log('ID and Suggested Raw Tone List:');
  console.log('================================');
  
  analysisData.results.forEach(result => {
    console.log(`${result.id}: ${result.suggestedRawTone}`);
  });
  
  console.log('\n================================');
  console.log(`Total entries: ${analysisData.results.length}`);
}

// Run the extraction
extractIdAndRawTone();