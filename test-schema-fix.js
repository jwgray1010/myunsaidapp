#!/usr/bin/env node

// Quick test to verify our schema fixes work
const { DataLoaderService } = require('./api-backup/_lib/services/dataLoader.js');

async function testSchemaFix() {
  console.log('Testing schema fix for Zod tone errors...');
  
  try {
    const dataLoader = new DataLoaderService();
    await dataLoader.init();
    
    // Get advice items to test our new schema
    const adviceItems = dataLoader.getAllAdviceItems();
    
    console.log(`✅ Successfully loaded ${adviceItems.length} advice items`);
    
    // Check a few items to see the new fields
    const sampleItems = adviceItems.slice(0, 3);
    sampleItems.forEach((item, i) => {
      console.log(`\nSample ${i + 1}:`);
      console.log(`- ID: ${item.id}`);
      console.log(`- triggerTone: ${item.triggerTone}`);
      console.log(`- rawTone: ${JSON.stringify(item.rawTone)}`);
      console.log(`- uiCompat: ${JSON.stringify(item.uiCompat)}`);
    });
    
    console.log('\n✅ Schema validation successful! No Zod errors.');
    
  } catch (error) {
    console.error('❌ Schema test failed:', error.message);
    if (error.stack) {
      console.error(error.stack);
    }
  }
}

testSchemaFix();