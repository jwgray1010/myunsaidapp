# Local BERT Tokenizer Assets

This directory should contain the tokenizer files for BERT-base-uncased model.

## Required Files

To populate this directory, run the following Python code on a machine with transformers:

```python
from transformers import AutoTokenizer
import os

# Create directory if it doesn't exist
os.makedirs('./models/bert-base-uncased-tokenizer', exist_ok=True)

# Download and save tokenizer
tokenizer = AutoTokenizer.from_pretrained("bert-base-uncased")
tokenizer.save_pretrained("./models/bert-base-uncased-tokenizer")
```

This will create the following files:
- `tokenizer.json` - Main tokenizer configuration (preferred)
- `vocab.txt` - WordPiece vocabulary
- `tokenizer_config.json` - Tokenizer configuration
- `special_tokens_map.json` - Special token mappings

## Usage

The NLI service will load the tokenizer from this local directory to avoid network calls in production:

```typescript
this.tokenizer = await AutoTokenizer.from_pretrained(
  resolveLocalPath('models/bert-base-uncased-tokenizer')
);
```

## Important Notes

- These files must be committed to the repository
- The tokenizer family must match your ONNX model (BERT-base-uncased)
- Never use network URLs in production - always use local paths