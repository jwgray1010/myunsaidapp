#!/usr/bin/env python3
import json
import sys

# Context to category mapping
context_mapping = {
    "conflict": "conflict_resolution",
    "repair": "repair", 
    "boundary": "boundary",
    "planning": "practical",
    "co_parenting": "relationship",
    "work/school": "communication", 
    "safety": "emotional",
    "misunderstanding": "clarity",
    "general": "general"
}

def add_category_field():
    # Read the file
    with open('data/therapy_advice.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    # Process each item
    for item in data:
        if "contexts" in item and len(item["contexts"]) > 0:
            primary_context = item["contexts"][0]
            # Map to category using our mapping, default to "emotional"  
            category = context_mapping.get(primary_context, "emotional")
            item["category"] = category
        else:
            # Default category if no contexts
            item["category"] = "general"
    
    # Write back to file with proper formatting
    with open('data/therapy_advice.json', 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    
    print("✅ Added category field to all entries")

if __name__ == "__main__":
    add_category_field()