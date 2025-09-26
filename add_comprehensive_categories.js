const fs = require('fs');

const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));

// Comprehensive category mapping from primary context to logical category groups
const contextToCategoryMapping = {
  // Basic communication contexts
  'conflict': 'conflict_resolution',
  'boundary': 'boundary_setting', 
  'planning': 'coordination',
  'repair': 'relationship_repair',
  'support': 'emotional_support',
  'presence': 'emotional_support',
  'misunderstanding': 'communication_clarification',
  'co_parenting': 'coordination',
  'work/school': 'coordination',
  'safety': 'safety_concerns',
  'finances': 'coordination',
  'gratitude': 'positive_communication',
  'check_in': 'emotional_support',
  'celebration': 'positive_communication',
  'apology': 'relationship_repair',
  'emotional': 'emotional_support',
  'logistics': 'coordination',
  
  // Extended contexts  
  'general': 'general_communication',
  'disclosure': 'vulnerability_sharing',
  'humor': 'positive_communication',
  'intimacy': 'intimacy_connection',
  'negotiation': 'conflict_resolution',
  'request': 'coordination',
  'critique': 'feedback_communication',
  'escalation': 'conflict_resolution',
  'decision': 'decision_making',
  'praise': 'positive_communication',
  'rupture': 'relationship_repair',
  'reassurance': 'emotional_support',
  'defense': 'self_protection',
  'withdrawal': 'self_protection',
  'dating': 'relationship_development',
  'financial': 'coordination',
  
  // Attachment patterns
  'anxious.pattern': 'attachment_awareness',
  'avoidant.pattern': 'attachment_awareness', 
  'disorganized.pattern': 'attachment_awareness',
  'secure.pattern': 'attachment_awareness',
  
  // Process contexts
  'conflict_prevention': 'conflict_resolution',
  'group_chat': 'group_communication',
  'validation': 'emotional_support',
  'encouragement': 'positive_communication',
  'emotional_support': 'emotional_support',
  'withdrawal_check': 'self_protection',
  'boundaries': 'boundary_setting',
  'rapport_building': 'relationship_development',
  'safety_check': 'safety_concerns',
  'expectations': 'coordination',
  'shame_reframe': 'emotional_support',
  'habits': 'personal_development',
  'signal_protocols': 'communication_structure',
  'thread_management': 'communication_structure',
  'vulnerability_disclosure': 'vulnerability_sharing',
  'tone_check': 'communication_awareness',
  'self_regulation': 'personal_development',
  'execution': 'coordination',
  'grief_shame': 'emotional_support',
  'self_worth_check': 'emotional_support',
  'meaning_making': 'emotional_support',
  'accountability': 'relationship_repair',
  'crisis': 'safety_concerns',
  'decision_making': 'decision_making',
  'insecurity': 'emotional_support',
  'comparison': 'emotional_support',
  'values': 'personal_development',
  'social_media': 'digital_communication',
  'process_guardrails': 'communication_structure',
  'identity_protection': 'self_protection',
  'labeling': 'communication_awareness',
  'jealousy': 'emotional_support',
  'pursuit': 'relationship_development',
  'sex_tone': 'intimacy_connection',
  'triangulation': 'conflict_resolution',
  'substances': 'safety_concerns',
  'early_stage': 'relationship_development',
  'post_date': 'relationship_development',
  'appreciation': 'positive_communication',
  
  // Financial contexts
  'budgeting': 'coordination',
  'spending': 'coordination',
  'debt': 'coordination',
  'fairness': 'conflict_resolution',
  'tracking': 'coordination',
  'big_purchase': 'coordination',
  'labor_balance': 'coordination',
  'shame_triggers': 'emotional_support',
  'repayment': 'coordination',
  'subscriptions': 'coordination',
  'gifts': 'positive_communication',
  'family_requests': 'coordination',
  'scorekeeping': 'conflict_resolution',
  'overwhelm': 'emotional_support',
  'cosign': 'coordination',
  'income_gap': 'coordination',
  'agreement_capture': 'communication_structure',
  
  // Group communication
  'exclusion_fear': 'emotional_support',
  'invites': 'coordination',
  'events': 'coordination',
  'misread_risk': 'communication_awareness',
  'privacy': 'boundary_setting',
  'cancellation': 'coordination',
  'read_receipts': 'digital_communication',
  'group_add': 'group_communication',
  'coordination': 'coordination',
  'pressure': 'boundary_setting',
  'gossip': 'group_communication',
  
  // Advanced communication contexts
  'scope': 'communication_structure',
  'length_management': 'communication_structure',
  'timing': 'communication_structure',
  'rejection_fear': 'emotional_support',
  'shame': 'emotional_support',
  'trust_test': 'relationship_development',
  'intention_signaling': 'communication_awareness',
  'impulse_control': 'personal_development',
  'channel_fit': 'communication_structure',
  'need_downplay': 'self_protection',
  'presence_limits': 'boundary_setting',
  'evidence_sprawl': 'communication_structure',
  'post_disclosure': 'vulnerability_sharing',
  'defensiveness': 'self_protection',
  'risk_testing': 'relationship_development',
  'receiving_vulnerability': 'vulnerability_sharing',
  'closure': 'communication_structure',
  'distraction': 'communication_awareness',
  'attunement': 'emotional_support',
  'lane_labeling': 'communication_structure',
  'timeboxing': 'communication_structure',
  'meaning_check': 'communication_awareness',
  'context_setup': 'communication_structure',
  'readability': 'communication_structure',
  'support_fit': 'emotional_support',
  'emotion_regulation': 'personal_development',
  'advice_mismatch': 'communication_awareness',
  'distraction_control': 'personal_development',
  'parts_language': 'communication_structure',
  'bandwidth_low': 'communication_awareness',
  'co_regulation': 'emotional_support',
  'lane_discipline': 'communication_structure',
  'assumption_risk': 'communication_awareness',
  'control_impulse': 'personal_development',
  'protest_behavior': 'self_protection',
  'ultimatum_risk': 'conflict_resolution',
  'modality_choice': 'communication_structure',
  'social_audit': 'digital_communication',
  'update_cadence': 'communication_structure',
  'history_spiral': 'emotional_support',
  'reassurance_fit': 'emotional_support',
  'cross_talk': 'communication_structure',
  'purpose_labeling': 'communication_structure',
  'ruleset': 'communication_structure',
  'rehash_loop': 'communication_structure',
  'tone_policing_risk': 'communication_awareness',
  'stakes_high': 'communication_awareness',
  'ambiguity': 'communication_clarification',
  'modality_handoff': 'communication_structure',
  'global_labels': 'communication_awareness',
  'wording_defense': 'self_protection',
  'talk_over': 'communication_structure',
  'late_night': 'communication_awareness',
  'ownership': 'coordination',
  'sarcasm_risk': 'communication_awareness',
  'ask_clarity': 'communication_clarification',
  'bandwidth_limits': 'communication_awareness',
  'feedback_fit': 'feedback_communication',
  'recognition': 'positive_communication',
  'decision_load': 'decision_making',
  'scheduling': 'coordination',
  'handoff': 'coordination',
  'labor_split': 'coordination',
  'nudging': 'coordination',
  'goal_alignment': 'coordination',
  'prioritization': 'decision_making',
  'help_request': 'coordination',
  'format_preference': 'communication_structure',
  'rituals': 'relationship_development',
  'stress_state': 'emotional_support',
  'teasing': 'positive_communication',
  'tone_markers': 'communication_structure',
  'bandwidth_check': 'communication_awareness',
  'consent_to_play': 'boundary_setting',
  'arousal_management': 'intimacy_connection',
  'situational_safety': 'safety_concerns',
  'surveillance_impulse': 'self_protection',
  'pause_protocol': 'communication_structure',
  'routine_checkin': 'emotional_support',
  'focus': 'communication_structure',
  'brevity': 'communication_structure',
  'backup_plan': 'coordination',
  'consent_to_advice': 'boundary_setting',
  'constraint_validation': 'communication_awareness',
  'pacing': 'communication_structure',
  'anti_globalizing': 'communication_awareness',
  'values_alignment': 'personal_development',
  'need_translation': 'communication_clarification',
  'tone_policing': 'communication_awareness',
  'character_attack': 'conflict_resolution',
  'documentation': 'communication_structure',
  'clarity': 'communication_clarification',
  'preference_check': 'communication_awareness',
  'pursuit_urge': 'relationship_development',
  'reassurance_seeking': 'emotional_support',
  'over_explaining': 'communication_awareness',
  'withdrawal_impulse': 'self_protection',
  'disclosure_min': 'vulnerability_sharing',
  'critique_impulse': 'feedback_communication',
  'scope_shrink': 'communication_structure',
  'approach_avoid_cycle': 'self_protection',
  'fragmentation': 'communication_structure',
  'arousal_spike': 'intimacy_connection',
  'boundary_flip': 'boundary_setting',
  'dissociation': 'emotional_support',
  'early_dating': 'relationship_development',
  'flake_risk': 'relationship_development',
  'first_date': 'relationship_development',
  'infatuation_risk': 'relationship_development',
  'Q&A_imbalance': 'communication_structure',
  'future_tripping': 'emotional_support',
  'intimacy_pace': 'intimacy_connection',
  'pace_mismatch': 'relationship_development',
  'exclusion_feelings': 'emotional_support',
  'rsvp_pressure': 'coordination',
  'dominance': 'conflict_resolution',
  'change_management': 'coordination'
};

let added = 0;
let alreadyHasCategory = 0;
let noMapping = [];

data.forEach(item => {
  // Check if already has category field
  if (item.category) {
    alreadyHasCategory++;
    return;
  }
  
  // Get primary context (first item in contexts array)
  if (item.contexts && item.contexts.length > 0) {
    const primaryContext = item.contexts[0];
    const category = contextToCategoryMapping[primaryContext];
    
    if (category) {
      item.category = category;
      added++;
    } else {
      noMapping.push(primaryContext);
    }
  }
});

fs.writeFileSync('data/therapy_advice.json', JSON.stringify(data, null, 2));
console.log(`Added category field to ${added} entries`);
console.log(`${alreadyHasCategory} entries already had category field`);

if (noMapping.length > 0) {
  console.log(`\nUnmapped contexts (${noMapping.length}):`);
  [...new Set(noMapping)].sort().forEach(ctx => console.log(`  ${ctx}`));
}

// Show the unique categories created
const categories = new Set();
data.forEach(item => {
  if (item.category) {
    categories.add(item.category);
  }
});

console.log(`\nCategories created (${categories.size}):`);
Array.from(categories).sort().forEach(cat => console.log(`  ${cat}`));