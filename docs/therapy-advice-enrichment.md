# Therapy Advice Context Enrichment

## Overview
The therapy advice system has been standardized to use **31 core context categories** as the single source of truth. Each advice item now includes enriched metadata for better targeting and filtering.

## Core Context Categories

### Conflict & Resolution (7 categories)
- `conflict` - Direct conflict situations
- `escalation` - When tensions are rising  
- `repair` - Post-conflict repair work
- `rupture` - Relationship ruptures
- `rupture_repair` - Specific rupture repair work
- `micro-apology` - Small apologies
- `apology` - Formal apologies

### Relationship Dynamics (6 categories) 
- `general` - General relationship situations
- `boundaries` - Setting boundaries (plural form)
- `boundary` - Boundary-related issues (singular form)
- `power_imbalance` - Power dynamics
- `validation` - Validation needs
- `safety` - Safety concerns

### Emotional States (6 categories)
- `insecurity` - Insecurity feelings
- `jealousy` - Jealousy situations
- `jealousy_comparison` - Comparison-based jealousy
- `comparison` - General comparison issues
- `longing` - Longing/yearning feelings
- `hesitation` - Hesitation/uncertainty

### Connection & Intimacy (6 categories)
- `intimacy` - Intimate moments
- `presence` - Being present
- `co-regulation` - Mutual regulation (hyphenated)
- `co_regulation` - Mutual regulation (underscore)
- `vulnerability_disclosure` - Sharing vulnerabilities
- `disclosure` - General disclosure

### Specific Relationship Areas (6 categories)
- `co-parenting` - Co-parenting situations
- `parenting` - General parenting
- `planning` - Planning together
- `praise` - Giving praise/recognition
- `invisible_labor` - Unrecognized work
- `mental_health_checkin` - Mental health check-ins

## Enriched Data Structure

Each therapy advice item now includes:

```json
{
  "id": "TA001",
  "advice": "Original advice text...",
  "core_contexts": ["conflict", "escalation"],
  "intents": ["deescalate", "clarify", "interrupt_spiral"],
  "triggerTone": "calm", 
  "tags": ["ctx:conflict", "ctx:escalation", "somatic"],
  // ... original fields preserved
}
```

### New Fields Explained

- **`core_contexts`**: Array of standardized context categories (restricted to the 31 core list)
- **`intents`**: Derived behavioral intents based on contexts (e.g., "deescalate", "set_boundary")
- **`triggerTone`**: Derived tone classification ("calm", "firm", "warm", "protective", "accountable", "neutral")
- **`tags`**: Semantic tags including context prefixes and content indicators

## Context Assignment Logic

The enrichment uses three methods:

1. **ID Range Heuristics**: Different TA number ranges map to likely contexts
2. **Keyword Matching**: Content analysis for specific terms and phrases
3. **Alias Normalization**: Smart mapping of variants (e.g., co-regulation → co_regulation)

## Usage Statistics

After enrichment (1,040 total items):
- **planning**: 226 items (logistics, scheduling)
- **repair**: 159 items (relationship repair)
- **conflict**: 157 items (conflict situations)
- **escalation**: 125 items (tension management)
- **vulnerability_disclosure**: 109 items (safe sharing)

## Files

- `data/therapy_advice.json` - Current enriched version (active)
- `data/therapy_advice.original.json` - Pre-enrichment backup
- `data/therapy_advice.enriched.json` - Intermediate enriched version
- `enrich_core.js` - Enrichment script

## Re-running Enrichment

To re-enrich after changes:

```bash
node enrich_core.js data/therapy_advice.original.json
# Review data/therapy_advice.enriched.json
# Replace main file if satisfied
```

The enrichment script preserves existing fields while adding new standardized metadata.