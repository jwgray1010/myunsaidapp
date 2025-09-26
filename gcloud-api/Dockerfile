# Use Node.js 18+ for compatibility with your dependencies
FROM node:18-slim

# Install system dependencies needed for native modules
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy package files first (better Docker caching)
COPY package*.json ./
COPY tsconfig.json ./

# Install all dependencies (including dev dependencies for TypeScript)
RUN npm ci

# Copy source code and data
COPY . .

# Build TypeScript to JavaScript
RUN npm run build

# Remove dev dependencies to reduce image size
RUN npm ci --only=production && npm cache clean --force

# Create a non-root user for security
RUN useradd -r -u 1001 appuser && chown -R appuser:appuser /app
USER appuser

# Expose port (Cloud Run will set PORT env var, default to 8080)
EXPOSE 8080

# Health check - temporarily disabled for debugging
# HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
#     CMD curl -f http://localhost:8080/health || exit 1

# Start the application (compiled JavaScript)
CMD ["npm", "start"]