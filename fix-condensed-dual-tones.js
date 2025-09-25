#!/usr/bin/env node

// Script to both condense format and apply dual trigger tones
const fs = require('fs');
const path = require('path');

// Dual tone assignments (from our previous work)
const dualToneAssignments = {
    'TA001': 'alert,angry',
    'TA002': 'alert,frustrated',
    'TA003': 'alert,defensive',
    'TA004': 'alert,defensive',
    'TA005': 'alert,confused_ambivalent',
    'TA006': 'caution,anxious',
    'TA007': 'alert,dismissive',
    'TA008': 'caution,curious',
    'TA009': 'alert,angry',
    'TA010': 'alert,withdrawn',
    'TA011': 'caution,supportive',
    'TA012': 'alert,catastrophizing',
    'TA013': 'alert,withdrawn',
    'TA014': 'alert,frustrated',
    'TA015': 'caution,reflective',
    'TA016': 'alert,defensive',
    'TA017': 'alert,catastrophizing',
    'TA018': 'caution,defensive',
    'TA019': 'caution,supportive',
    'TA020': 'alert,defensive'
};

function loadTherapyAdvice() {
    try {
        const advicePath = path.join(__dirname, 'data', 'therapy_advice.json');
        const advice = JSON.parse(fs.readFileSync(advicePath, 'utf8'));
        return advice;
    } catch (error) {
        console.error('Error loading therapy advice:', error);
        return null;
    }
}

function condenseAndApplyDualTones() {
    console.log('🎯 Condensing Format AND Applying Dual Trigger Tones\n');
    
    const advice = loadTherapyAdvice();
    if (!advice) {
        console.error('Failed to load therapy advice');
        return;
    }
    
    let updatedCount = 0;
    
    // Update first 20 entries
    for (let i = 0; i < Math.min(20, advice.length); i++) {
        const entry = advice[i];
        const entryId = entry.id;
        
        // Get dual tone assignment
        const dualTone = dualToneAssignments[entryId] || entry.triggerTone;
        
        console.log(`${entryId}: "${entry.triggerTone}" → "${dualTone}"`);
        console.log(`   Advice: "${entry.advice.substring(0, 60)}..."`);
        
        // Apply dual tone
        entry.triggerTone = dualTone;
        
        updatedCount++;
    }
    
    // Write back to file
    try {
        const advicePath = path.join(__dirname, 'data', 'therapy_advice.json');
        fs.writeFileSync(advicePath, JSON.stringify(advice, null, 2), 'utf8');
        console.log(`\n✅ Successfully updated ${updatedCount} entries`);
        console.log(`📁 Updated file: ${advicePath}`);
    } catch (error) {
        console.error('Error writing therapy advice file:', error);
    }
}

// Run the update
if (require.main === module) {
    condenseAndApplyDualTones();
}

module.exports = {
    dualToneAssignments,
    condenseAndApplyDualTones
};