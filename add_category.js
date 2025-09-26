const fs = require('fs');

// Context to Category mapping
const contextToCategory = {
  // Conflict Resolution
  "conflict": "conflict_resolution",
  "conflict_prevention": "conflict_resolution", 
  "repair": "conflict_resolution",
  "rupture": "conflict_resolution",
  "character_attack": "conflict_resolution",
  "defense": "conflict_resolution",
  "defensiveness": "conflict_resolution",
  "escalation": "conflict_resolution",
  
  // Communication
  "clarity": "communication",
  "ask_clarity": "communication",
  "meaning_check": "communication",
  "meaning_making": "communication",
  "misunderstanding": "communication",
  "misread_risk": "communication",
  "ambiguity": "communication",
  "tone_check": "communication",
  "tone_markers": "communication",
  "readability": "communication",
  "brevity": "communication",
  "length_management": "communication",
  "wording_defense": "communication",
  "over_explaining": "communication",
  "format_preference": "communication",
  "modality_choice": "communication",
  "modality_handoff": "communication",
  
  // Boundaries
  "boundary": "boundaries",
  "boundaries": "boundaries",
  "boundary_flip": "boundaries",
  "lane_discipline": "boundaries",
  "lane_labeling": "boundaries",
  "privacy": "boundaries",
  "consent_to_advice": "boundaries",
  "consent_to_play": "boundaries",
  
  // Planning & Logistics  
  "planning": "planning",
  "logistics": "planning",
  "scheduling": "planning",
  "coordination": "planning",
  "decision": "planning",
  "decision_making": "planning",
  "decision_load": "planning",
  "execution": "planning",
  "timeboxing": "planning",
  "timing": "planning",
  "backup_plan": "planning",
  "handoff": "planning",
  "cancellation": "planning",
  "invites": "planning",
  "events": "planning",
  "rsvp_pressure": "planning",
  
  // Emotional Support
  "support": "emotional_support",
  "emotional_support": "emotional_support",
  "presence": "emotional_support",
  "validation": "emotional_support", 
  "reassurance": "emotional_support",
  "reassurance_seeking": "emotional_support",
  "reassurance_fit": "emotional_support",
  "encouragement": "emotional_support",
  "praise": "emotional_support",
  "appreciation": "emotional_support",
  "gratitude": "emotional_support",
  "recognition": "emotional_support",
  
  // Relationship Dynamics
  "intimacy": "relationship_dynamics",
  "intimacy_pace": "relationship_dynamics",
  "vulnerability_disclosure": "relationship_dynamics",
  "receiving_vulnerability": "relationship_dynamics",
  "disclosure": "relationship_dynamics",
  "disclosure_min": "relationship_dynamics",
  "trust_test": "relationship_dynamics",
  "jealousy": "relationship_dynamics",
  "insecurity": "relationship_dynamics",
  "comparison": "relationship_dynamics",
  "pursuit": "relationship_dynamics",
  "pursuit_urge": "relationship_dynamics",
  "withdrawal": "relationship_dynamics",
  "withdrawal_check": "relationship_dynamics",
  "withdrawal_impulse": "relationship_dynamics",
  "attunement": "relationship_dynamics",
  "co_regulation": "relationship_dynamics",
  "approach_avoid_cycle": "relationship_dynamics",
  
  // Self-Regulation
  "emotion_regulation": "self_regulation",
  "self_regulation": "self_regulation",
  "arousal_management": "self_regulation", 
  "arousal_spike": "self_regulation",
  "impulse_control": "self_regulation",
  "control_impulse": "self_regulation",
  "pause_protocol": "self_regulation",
  "distraction": "self_regulation",
  "distraction_control": "self_regulation",
  "overwhelm": "self_regulation",
  "stress_state": "self_regulation",
  "dissociation": "self_regulation",
  "substances": "self_regulation",
  
  // Dating & Relationships
  "dating": "dating",
  "early_dating": "dating",
  "early_stage": "dating", 
  "first_date": "dating",
  "post_date": "dating",
  "infatuation_risk": "dating",
  "flake_risk": "dating",
  "sex_tone": "dating",
  
  // Co-parenting
  "co_parenting": "co_parenting",
  "family_requests": "co_parenting",
  
  // Work/School
  "work/school": "work_school",
  
  // Safety & Crisis
  "safety": "safety",
  "safety_check": "safety", 
  "situational_safety": "safety",
  "crisis": "safety",
  
  // Financial
  "financial": "financial",
  "budgeting": "financial",
  "spending": "financial",
  "big_purchase": "financial",
  "debt": "financial",
  "income_gap": "financial", 
  "subscriptions": "financial",
  "repayment": "financial",
  
  // Default for unmapped contexts
  "general": "general"
};

const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));
let added = 0;

data.forEach(item => {
  if (item.contexts && item.contexts.length > 0) {
    const primaryContext = item.contexts[0];
    const category = contextToCategory[primaryContext] || "general";
    item.category = category;
    added++;
  }
});

fs.writeFileSync('data/therapy_advice.json', JSON.stringify(data, null, 2));
console.log(`Added category field to ${added} entries`);