// api/_lib/utils/ahoCorasick.ts
// Shared Aho-Corasick automaton utility for efficient multi-pattern matching
// Used by tone analysis, content filtering, and other pattern matching needs

interface PatternMatch<T = any> {
  pattern: string;
  start: number;
  end: number;
  data: T;
}

class AhoCorasickNode<T = any> {
  children = new Map<string, AhoCorasickNode<T>>();
  failure: AhoCorasickNode<T> | null = null;
  output: Array<{ pattern: string; data: T }> = [];
}

export class AhoCorasickAutomaton<T = any> {
  private root = new AhoCorasickNode<T>();
  private built = false;
  private patternCount = 0;

  /**
   * Add a pattern to the automaton
   * @param pattern Space-separated tokens or single token
   * @param data Associated data for this pattern
   */
  addPattern(pattern: string, data: T): void {
    let node = this.root;
    const tokens = pattern.trim().split(/\s+/);
    
    for (const token of tokens) {
      if (!node.children.has(token)) {
        node.children.set(token, new AhoCorasickNode<T>());
      }
      node = node.children.get(token)!;
    }
    
    node.output.push({ pattern: pattern.trim(), data });
    this.built = false; // Mark as needing rebuild
    this.patternCount++;
  }

  /**
   * Add multiple patterns at once
   */
  addPatterns(patterns: Array<{ pattern: string; data: T }>): void {
    for (const { pattern, data } of patterns) {
      this.addPattern(pattern, data);
    }
  }

  /**
   * Build failure links (automatically called by search if needed)
   */
  private build(): void {
    if (this.built) return;
    
    // Build failure links using BFS
    const queue: AhoCorasickNode<T>[] = [];
    
    // Initialize first level - all direct children of root have failure links to root
    for (const child of this.root.children.values()) {
      child.failure = this.root;
      queue.push(child);
    }
    
    // Build failure links for deeper levels
    while (queue.length > 0) {
      const currentNode = queue.shift()!;
      
      for (const [char, childNode] of currentNode.children) {
        queue.push(childNode);
        
        // Find the longest proper suffix that's also a prefix
        let failureNode = currentNode.failure;
        while (failureNode !== null && !failureNode.children.has(char)) {
          failureNode = failureNode.failure;
        }
        
        if (failureNode === null) {
          childNode.failure = this.root;
        } else {
          childNode.failure = failureNode.children.get(char)!;
          // Inherit output patterns from failure node (suffix matches)
          childNode.output.push(...childNode.failure.output);
        }
      }
    }
    
    this.built = true;
  }

  /**
   * Search for all pattern matches in the given token sequence
   * @param tokens Array of tokens to search through
   * @returns Array of pattern matches with positions
   */
  search(tokens: string[]): PatternMatch<T>[] {
    this.build();
    
    const results: PatternMatch<T>[] = [];
    let currentNode = this.root;
    
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      
      // Follow failure links until we find a match or reach root
      while (currentNode !== this.root && !currentNode.children.has(token)) {
        currentNode = currentNode.failure!;
      }
      
      // Move to next node if possible
      if (currentNode.children.has(token)) {
        currentNode = currentNode.children.get(token)!;
        
        // Report all patterns that end at this position
        for (const match of currentNode.output) {
          const patternLength = match.pattern.split(/\s+/).length;
          const start = i - patternLength + 1;
          
          results.push({
            pattern: match.pattern,
            start: Math.max(0, start), // Ensure non-negative
            end: i,
            data: match.data
          });
        }
      }
    }
    
    return results;
  }

  /**
   * Clear all patterns and reset the automaton
   */
  clear(): void {
    this.root = new AhoCorasickNode<T>();
    this.built = false;
    this.patternCount = 0;
  }

  /**
   * Get statistics about the automaton
   */
  getStats() {
    return {
      patternCount: this.patternCount,
      isBuilt: this.built,
      hasPatterns: this.patternCount > 0
    };
  }

  /**
   * Check if a specific pattern exists in the automaton
   */
  hasPattern(pattern: string): boolean {
    let node = this.root;
    const tokens = pattern.trim().split(/\s+/);
    
    for (const token of tokens) {
      if (!node.children.has(token)) {
        return false;
      }
      node = node.children.get(token)!;
    }
    
    return node.output.some(output => output.pattern === pattern.trim());
  }
}

// Factory function for common use cases
export function createPatternMatcher<T = any>(): AhoCorasickAutomaton<T> {
  return new AhoCorasickAutomaton<T>();
}

// Utility for simple string matching (no additional data)
export function createStringMatcher(): AhoCorasickAutomaton<boolean> {
  return new AhoCorasickAutomaton<boolean>();
}