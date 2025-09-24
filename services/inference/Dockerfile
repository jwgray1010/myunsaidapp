FROM node:20-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production

# Install curl for downloading models
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

COPY --from=deps /app/node_modules ./node_modules
COPY tsconfig.json ./
COPY src ./src
COPY data ./data

# Create models directory and download model files
RUN mkdir -p models && \
    cd models && \
    # Download MiniLM model for sentence embeddings
    curl -L -o minilm.onnx "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx" && \
    # Download tokenizer files
    mkdir -p tokenizer && \
    cd tokenizer && \
    curl -L -o config.json "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/tokenizer_config.json" && \
    curl -L -o tokenizer.json "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/tokenizer.json" && \
    curl -L -o vocab.json "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/vocab.json" && \
    curl -L -o merges.txt "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/merges.txt" && \
    curl -L -o special_tokens_map.json "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/special_tokens_map.json"

RUN npx tsc
EXPOSE 8080
CMD ["node", "dist/server.js"]