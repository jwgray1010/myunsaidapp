// api/_lib/services/dialogueState.ts
export type DialogueSlots = {
  topic?: string;
  timeframe?: string;
  ask?: string;
  boundary?: boolean;
  repair?: boolean;
};

export type DialogueState = {
  lastContext: 'general'|'conflict'|'repair'|'boundary'|'planning'|string;
  lastTone: 'clear'|'caution'|'alert'|string;
  turns: number;
  lastUpdated: string;
  slots: DialogueSlots;
};

const DEFAULT: DialogueState = {
  lastContext: 'general',
  lastTone: 'clear',
  turns: 0,
  lastUpdated: new Date().toISOString(),
  slots: {}
};

export class DialogueStateStore {
  private state: DialogueState;
  constructor(private userId: string, initial?: Partial<DialogueState>) {
    this.state = { ...DEFAULT, ...initial };
  }
  
  get() { 
    return this.state; 
  }

  update(p: Partial<DialogueState>, text?: string) {
    this.state = { 
      ...this.state, 
      ...p, 
      turns: this.state.turns + 1, 
      lastUpdated: new Date().toISOString() 
    };
    
    if (text) {
      // Extract dialogue patterns from text
      if (/\bcan we\b|\bcould we\b|\bplease\b/i.test(text)) {
        this.state.slots.ask = 'specific_request';
      }
      
      if (/\bi need\b.*\b(space|break|time)\b/i.test(text)) {
        this.state.slots.boundary = true;
      }
      
      if (/\bstart over\b|\bfix this\b|\bthat wasn'?t fair/i.test(text)) {
        this.state.slots.repair = true;
      }
      
      const tf = text.match(/\b(today|tonight|tomorrow|this week|next week)\b/i);
      if (tf) {
        this.state.slots.timeframe = tf[1].toLowerCase();
      }
    }
  }
}