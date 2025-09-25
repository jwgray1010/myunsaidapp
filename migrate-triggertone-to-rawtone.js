#!/usr/bin/env node

/**
 * Therapy Advice TriggerTone to RawTone Migration Script
 * 
 * Usage: node migrate-triggertone-to-rawtone.js
 * 
 * This script migrates triggerTone values that aren't UI buckets (alert, caution, clear)
 * into a new rawTone field, keeping the UI buckets in triggerTone.
 * 
 * Example transformation:
 * Before: "triggerTone": ["alert", "angry", "frustrated"]
 * After:  "triggerTone": ["alert"], "rawTone": ["angry", "frustrated"]
 */

const fs = require('fs');
const path = require('path');

// UI bucket tones that stay in triggerTone
const UI_BUCKETS = new Set(['alert', 'caution', 'clear', 'neutral']);

// Raw tones from evaluation_tones.json that should be moved to rawTone
const RAW_TONES = new Set([
  'neutral', 'positive', 'supportive', 'anxious', 'angry', 'frustrated', 'sad', 
  'assertive', 'safety_concern', 'withdrawn', 'apologetic', 'curious', 'dismissive', 
  'defensive', 'jealous_insecure', 'catastrophizing', 'minimization', 'playful', 
  'reflective', 'logistical', 'confused_ambivalent'
]);

function migrateTherapyAdvice() {
  const therapyAdvicePath = path.join(__dirname, 'data', 'therapy_advice.json');
  
  try {
    console.log('🔄 Loading therapy_advice.json...');
    const data = fs.readFileSync(therapyAdvicePath, 'utf8');
    const therapyAdvice = JSON.parse(data);
    
    let migrationCount = 0;
    let totalProcessed = 0;
    
    console.log(`📊 Processing ${therapyAdvice.length} therapy advice entries...`);
    
    therapyAdvice.forEach((entry, index) => {
      totalProcessed++;
      
      if (!entry.triggerTone || !Array.isArray(entry.triggerTone)) {
        return; // Skip entries without triggerTone array
      }
      
      // Separate UI buckets from raw tones
      const uiBucketTones = [];
      const rawTones = [];
      
      entry.triggerTone.forEach(tone => {
        if (UI_BUCKETS.has(tone)) {
          uiBucketTones.push(tone);
        } else if (RAW_TONES.has(tone)) {
          rawTones.push(tone);
        } else {
          console.warn(`⚠️  Unknown tone "${tone}" in entry ${entry.id} - keeping in triggerTone`);
          uiBucketTones.push(tone); // Keep unknown tones in triggerTone for safety
        }
      });
      
      // Only migrate if we found raw tones to move
      if (rawTones.length > 0) {
        migrationCount++;
        
        // Update triggerTone to only contain UI buckets
        entry.triggerTone = uiBucketTones;
        
        // Add rawTone field with the raw tones
        entry.rawTone = rawTones;
        
        console.log(`✨ ${entry.id}: triggerTone=[${uiBucketTones.join(',')}] rawTone=[${rawTones.join(',')}]`);
      }
    });
    
    // Write the updated data back to the file
    const updatedJson = JSON.stringify(therapyAdvice, null, 2);
    fs.writeFileSync(therapyAdvicePath, updatedJson, 'utf8');
    
    console.log('\n🎉 Migration Complete!');
    console.log(`📈 Processed: ${totalProcessed} entries`);
    console.log(`🔄 Migrated: ${migrationCount} entries with raw tones`);
    console.log(`💾 Updated: ${therapyAdvicePath}`);
    
    // Show sample of what changed
    if (migrationCount > 0) {
      console.log('\n📋 Sample migration results:');
      const samples = therapyAdvice.filter(entry => entry.rawTone).slice(0, 3);
      samples.forEach(entry => {
        console.log(`  ${entry.id}:`);
        console.log(`    triggerTone: [${entry.triggerTone.join(', ')}]`);
        console.log(`    rawTone: [${entry.rawTone.join(', ')}]`);
      });
    }
    
  } catch (error) {
    console.error('❌ Error during migration:', error.message);
    process.exit(1);
  }
}

function validateMigration() {
  console.log('\n🔍 Running post-migration validation...');
  
  const therapyAdvicePath = path.join(__dirname, 'data', 'therapy_advice.json');
  const data = fs.readFileSync(therapyAdvicePath, 'utf8');
  const therapyAdvice = JSON.parse(data);
  
  let validationErrors = [];
  let entriesWithRawTone = 0;
  
  therapyAdvice.forEach(entry => {
    // Check that triggerTone only contains UI buckets
    if (entry.triggerTone && Array.isArray(entry.triggerTone)) {
      entry.triggerTone.forEach(tone => {
        if (!UI_BUCKETS.has(tone) && RAW_TONES.has(tone)) {
          validationErrors.push(`${entry.id}: Raw tone "${tone}" still in triggerTone`);
        }
      });
    }
    
    // Check that rawTone only contains raw tones
    if (entry.rawTone && Array.isArray(entry.rawTone)) {
      entriesWithRawTone++;
      entry.rawTone.forEach(tone => {
        if (UI_BUCKETS.has(tone)) {
          validationErrors.push(`${entry.id}: UI bucket "${tone}" found in rawTone`);
        }
        if (!RAW_TONES.has(tone)) {
          validationErrors.push(`${entry.id}: Unknown tone "${tone}" in rawTone`);
        }
      });
    }
  });
  
  if (validationErrors.length > 0) {
    console.log('❌ Validation errors found:');
    validationErrors.forEach(error => console.log(`  - ${error}`));
  } else {
    console.log('✅ Validation passed!');
    console.log(`📊 Found ${entriesWithRawTone} entries with rawTone field`);
  }
}

// Main execution
if (require.main === module) {
  console.log('🚀 Starting TriggerTone → RawTone Migration\n');
  
  migrateTherapyAdvice();
  validateMigration();
  
  console.log('\n✨ Migration script completed successfully!');
}

module.exports = {
  migrateTherapyAdvice,
  validateMigration,
  UI_BUCKETS,
  RAW_TONES
};