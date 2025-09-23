# Local ML Models Directory

This directory contains machine learning models and tokenizers used by the application.

## Directory Structure

```
models/
├── bert-base-uncased-tokenizer/     # BERT tokenizer assets
│   ├── README.md                    # Setup instructions
│   ├── tokenizer.json              # Main tokenizer config (to be added)
│   ├── vocab.txt                   # WordPiece vocabulary (to be added)
│   ├── tokenizer_config.json       # Config (to be added)
│   └── special_tokens_map.json     # Special tokens (to be added)
└── mnli-mini.onnx                   # MNLI model for entailment checking (to be added)
```

## Files to Add

### 1. BERT Tokenizer (`bert-base-uncased-tokenizer/`)

Run this Python code to download the tokenizer:

```python
from transformers import AutoTokenizer
tokenizer = AutoTokenizer.from_pretrained("bert-base-uncased")
tokenizer.save_pretrained("./models/bert-base-uncased-tokenizer")
```

### 2. MNLI Model (`mnli-mini.onnx`)

You need an ONNX-exported MNLI model. The model should:

- Be from the BERT-base-uncased family (to match the tokenizer)
- Have 3 output classes: [contradiction, neutral, entailment]
- Accept inputs: input_ids, attention_mask, token_type_ids (optional)
- Use int32 tensors for web compatibility

Example conversion script:

```python
from transformers import AutoModelForSequenceClassification
import torch.onnx

model = AutoModelForSequenceClassification.from_pretrained("microsoft/DialoGPT-medium")
# Export to ONNX format
torch.onnx.export(
    model,
    (input_ids, attention_mask, token_type_ids),
    "mnli-mini.onnx",
    input_names=["input_ids", "attention_mask", "token_type_ids"],
    output_names=["logits"],
    dynamic_axes={"input_ids": {0: "batch"}, "attention_mask": {0: "batch"}, "token_type_ids": {0: "batch"}}
)
```

## Important Notes

- All files must be committed to the repository
- No network calls allowed in production
- Model and tokenizer must be compatible (same architecture family)
- Test thoroughly after adding files