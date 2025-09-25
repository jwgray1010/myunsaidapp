#!/usr/bin/env node

// Script to add dual trigger tones (UI bucket + raw tone) to therapy advice entries
const fs = require('fs');
const path = require('path');

// Load therapy advice data
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

// Load evaluation tones for validation
function loadEvaluationTones() {
    try {
        const evalPath = path.join(__dirname, 'data', 'evaluation_tones.json');
        const evalData = JSON.parse(fs.readFileSync(evalPath, 'utf8'));
        return evalData.rawTones || [];
    } catch (error) {
        console.error('Error loading evaluation tones:', error);
        return [];
    }
}

// Attachment-style-aware analysis function
function analyzeAttachmentContext(entry) {
    const advice = entry.advice.toLowerCase();
    const attachmentStyles = entry.attachmentStyles || [];
    const contexts = entry.contexts || [];
    
    // Key phrase patterns that indicate specific raw tones
    const patterns = {
        angry: ['heated', 'volume', 'anger', 'rage', 'fury'],
        frustrated: ['frustrated', 'ignored', 'dismissed', 'unheard'],
        defensive: ['blame', 'you statements', 'defensiveness', 'sarcasm', 'body language'],
        anxious: ['criticism', 'breathe', 'pause', 'anxiety', 'worry'],
        withdrawn: ['break', 'space', 'cornered', 'withdraw', 'escape'],
        supportive: ['validate', 'support', 'with you', 'together', 'shared goal'],
        curious: ['clarity', 'explain', 'understand', 'ask', 'what you meant'],
        reflective: ['mirror', 'reflect', 'listen', 'thoughts', 'collect'],
        catastrophizing: ['always', 'never', 'future', 'project', 'worst'],
        confused_ambivalent: ['past each other', 'talking past', 'miscommunication'],
        dismissive: ['sarcasm', 'drop', 'plainly', 'direct'],
        assertive: ['need', 'boundary', 'statement', 'clear', 'direct']
    };
    
    // Score each raw tone based on content and attachment styles
    const scores = {};
    
    for (const [tone, keywords] of Object.entries(patterns)) {
        let score = 0;
        
        // Content matching
        keywords.forEach(keyword => {
            if (advice.includes(keyword)) {
                score += 2;
            }
        });
        
        // Attachment style weighting
        if (attachmentStyles.includes('anxious')) {
            if (['frustrated', 'supportive', 'curious', 'anxious'].includes(tone)) score += 1;
        }
        if (attachmentStyles.includes('avoidant')) {
            if (['withdrawn', 'defensive', 'angry', 'assertive'].includes(tone)) score += 1;
        }
        if (attachmentStyles.includes('disorganized')) {
            if (['defensive', 'confused_ambivalent', 'angry', 'withdrawn'].includes(tone)) score += 1;
        }
        if (attachmentStyles.includes('secure')) {
            if (['supportive', 'curious', 'reflective', 'assertive'].includes(tone)) score += 1;
        }
        
        // Context weighting
        if (contexts.includes('conflict')) {
            if (['angry', 'frustrated', 'defensive'].includes(tone)) score += 1;
        }
        if (contexts.includes('escalation')) {
            if (['angry', 'defensive', 'withdrawn'].includes(tone)) score += 1;
        }
        
        scores[tone] = score;
    }
    
    // Return the highest scoring tone
    const sortedTones = Object.entries(scores)
        .filter(([tone, score]) => score > 0)
        .sort((a, b) => b[1] - a[1]);
    
    return sortedTones.length > 0 ? sortedTones[0][0] : 'supportive'; // fallback
}

// Attachment-aware dual trigger tone assignments for first 20 entries
// These are carefully analyzed based on therapeutic intent and attachment patterns
const manualDualToneAssignments = {
    'TA001': 'alert,angry',        // "Pause before replying; name the heat" → All styles, especially anxious/disorganized who escalate quickly
    'TA002': 'alert,frustrated',   // "Name frustration... I felt ignored" → Anxious attachment - addresses core fear of being ignored
    'TA003': 'alert,defensive',    // "Don't repeat louder—slow down" → Avoidant/disorganized who struggle with volume control
    'TA004': 'alert,defensive',    // "Switch from 'you' to 'I' statements" → All styles when blame patterns emerge
    'TA005': 'alert,confused_ambivalent', // "Call out escalation: talking past each other" → Secure/disorganized for meta-awareness
    'TA006': 'caution,anxious',    // "Take three breaths before responding to criticism" → Avoidant who withdraw + secure who regulate
    'TA007': 'alert,dismissive',   // "Drop sarcasm; say plainly what you mean" → Disorganized/anxious who use sarcasm defensively
    'TA008': 'caution,curious',    // "Ask for clarity, not intent guesses" → Secure/anxious who seek understanding
    'TA009': 'alert,angry',        // "If volume rises: bring the tone down" → Avoidant/secure for volume regulation
    'TA010': 'alert,withdrawn',    // "State a behavioral need: pause for five minutes" → Secure/avoidant/anxious who need space
    'TA011': 'caution,supportive', // "Validate before countering" → Secure/anxious who prioritize connection
    'TA012': 'alert,catastrophizing', // "Avoid 'always/never'; keep to this moment" → Secure/avoidant when catastrophic thinking emerges
    'TA013': 'alert,withdrawn',    // "Buy time when cornered: need a break" → Avoidant/disorganized who need escape routes
    'TA014': 'alert,frustrated',   // "Don't bring old conflicts in" → Secure/disorganized who kitchen-sink
    'TA015': 'caution,reflective', // "Mirror the last sentence to confirm" → Secure/anxious for active listening
    'TA016': 'alert,defensive',    // "When blame spikes, name your own feelings" → Anxious/secure for self-awareness
    'TA017': 'alert,catastrophizing', // "Keep arguments present-tense; don't project future" → Secure/anxious/avoidant who future-trip
    'TA018': 'caution,defensive',  // "Soften body language—uncross arms" → Secure/disorganized for somatic awareness
    'TA019': 'caution,supportive', // "State the shared goal: we both want to solve this" → Secure/anxious for unity
    'TA020': 'alert,defensive'     // "Interrupt defensiveness: I'm not against you" → Secure/anxious/disorganized for reassurance
};

// Validation function to ensure raw tones are valid
function validateRawTone(rawTone, validTones) {
    return validTones.includes(rawTone);
}

// Update therapy advice with dual trigger tones
function updateDualTriggerTones(options = {}) {
    console.log('🎯 Updating Therapy Advice with Attachment-Aware Dual Trigger Tones\n');
    
    const advice = loadTherapyAdvice();
    const validRawTones = loadEvaluationTones();
    
    if (!advice) {
        console.error('Failed to load therapy advice');
        return;
    }
    
    console.log(`📋 Valid Raw Tones (${validRawTones.length}): ${validRawTones.join(', ')}\n`);
    
    let updatedCount = 0;
    let analysisMode = options.analysisMode || false;
    const maxEntries = options.maxEntries || 20;
    
    // Update entries
    for (let i = 0; i < Math.min(maxEntries, advice.length); i++) {
        const entry = advice[i];
        const entryId = entry.id;
        
        let newRawTone;
        let source = 'manual';
        
        // Use manual assignment if available, otherwise analyze
        if (manualDualToneAssignments[entryId]) {
            const [uiBucket, rawTone] = manualDualToneAssignments[entryId].split(',');
            newRawTone = rawTone;
        } else {
            newRawTone = analyzeAttachmentContext(entry);
            source = 'analyzed';
        }
        
        // Validate raw tone
        if (!validateRawTone(newRawTone, validRawTones)) {
            console.log(`⚠️  Invalid raw tone "${newRawTone}" for ${entryId}, using supportive as fallback`);
            newRawTone = 'supportive';
        }
        
        const oldTriggerTone = entry.triggerTone;
        const uiBucket = oldTriggerTone.includes(',') ? oldTriggerTone.split(',')[0] : oldTriggerTone;
        const newTriggerTone = `${uiBucket},${newRawTone}`;
        
        console.log(`${entryId} [${source}]: "${oldTriggerTone}" → "${newTriggerTone}"`);
        console.log(`   Advice: "${entry.advice.substring(0, 70)}..."`);
        console.log(`   Attachment Styles: [${entry.attachmentStyles?.join(', ') || 'none'}]`);
        console.log(`   Contexts: [${entry.contexts?.join(', ') || 'none'}]`);
        console.log('');
        
        if (!analysisMode) {
            entry.triggerTone = newTriggerTone;
        }
        updatedCount++;
    }
    
    // Write back to file (unless in analysis mode)
    if (!analysisMode) {
        try {
            const advicePath = path.join(__dirname, 'data', 'therapy_advice.json');
            fs.writeFileSync(advicePath, JSON.stringify(advice, null, 2), 'utf8');
            console.log(`✅ Successfully updated ${updatedCount} entries with dual trigger tones`);
            console.log(`📁 Updated file: ${advicePath}`);
        } catch (error) {
            console.error('Error writing therapy advice file:', error);
        }
    } else {
        console.log(`📊 Analysis complete for ${updatedCount} entries (no files modified)`);
    }
}

// Command line argument parsing
const args = process.argv.slice(2);
const analysisMode = args.includes('--analysis') || args.includes('-a');
const maxEntries = args.find(arg => arg.startsWith('--max='))?.split('=')[1] || 20;

// Run the update
if (require.main === module) {
    updateDualTriggerTones({ 
        analysisMode, 
        maxEntries: parseInt(maxEntries) 
    });
}

module.exports = {
    manualDualToneAssignments,
    analyzeAttachmentContext,
    updateDualTriggerTones
};