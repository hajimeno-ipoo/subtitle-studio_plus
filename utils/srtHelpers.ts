import { SubtitleItem } from '../types';

// Helper to format seconds to SRT timestamp format (00:00:00,000)
export const formatTime = (seconds: number): string => {
  const date = new Date(0);
  date.setSeconds(seconds);
  const iso = date.toISOString().substr(11, 8);
  const ms = Math.floor((seconds % 1) * 1000)
    .toString()
    .padStart(3, '0');
  return `${iso},${ms}`;
};

// Helper to parse SRT timestamp to seconds
// Handles 00:00:00,000 (HH:MM:SS,ms) and 00:00,000 (MM:SS,ms)
export const parseTime = (timeString: string): number => {
  if (!timeString) return 0;
  
  // Normalize comma to dot for parsing
  const normalized = timeString.replace(',', '.').trim();
  const parts = normalized.split(':');
  
  // Case: MM:SS.ms
  if (parts.length === 2) {
    const minutes = parseInt(parts[0], 10);
    const seconds = parseFloat(parts[1]);
    return minutes * 60 + seconds;
  }
  
  // Case: HH:MM:SS.ms
  if (parts.length >= 3) {
    const hours = parseInt(parts[0], 10);
    const minutes = parseInt(parts[1], 10);
    const seconds = parseFloat(parts[2]);
    return hours * 3600 + minutes * 60 + seconds;
  }

  return 0;
};

// Generate SRT string from SubtitleItems
export const generateSRT = (subtitles: SubtitleItem[]): string => {
  return subtitles
    .map((sub, index) => {
      return `${index + 1}\n${formatTime(sub.startTime)} --> ${formatTime(sub.endTime)}\n${sub.text}\n`;
    })
    .join('\n');
};

// Parse SRT string to SubtitleItems
// Robust state-machine based parser
export const parseSRT = (srtContent: string): SubtitleItem[] => {
  const normalizeLineEndings = srtContent.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = normalizeLineEndings.split('\n');
  
  const items: SubtitleItem[] = [];
  let currentItem: Partial<SubtitleItem> | null = null;
  let currentTextLines: string[] = [];

  // Regex for timestamp line:
  // IMPROVED: 
  // - Supports comma (,) or dot (.) for separator
  // - Make milliseconds optional (e.g., 00:00:05 is valid)
  // - Supports optional hours
  const timeRegex = /((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)\s*-?->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)/;

  const flushCurrentItem = () => {
    if (currentItem && currentTextLines.length > 0) {
      currentItem.text = currentTextLines.join('\n').trim();
      // Validate that we have times and text
      if (currentItem.startTime !== undefined && currentItem.endTime !== undefined && currentItem.text) {
        items.push(currentItem as SubtitleItem);
      }
    }
    currentItem = null;
    currentTextLines = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // Skip empty lines unless they separate blocks (handled by flushing)
    if (!line) {
       flushCurrentItem();
       continue;
    }

    // Check for timestamp
    const timeMatch = line.match(timeRegex);
    if (timeMatch) {
        // If we were building a previous item and hit a new timestamp (missing empty line case)
        if (currentItem) {
             flushCurrentItem();
        }
        
        // Start new item
        currentItem = {
            id: crypto.randomUUID(),
            startTime: parseTime(timeMatch[1]),
            endTime: parseTime(timeMatch[2]),
        };
        currentTextLines = [];
        continue;
    }

    // Check for Index (digits only)
    if (/^\d+$/.test(line)) {
        // Look ahead for timestamp to confirm it's an index
        const nextLine = lines[i+1]?.trim();
        if (nextLine && timeRegex.test(nextLine)) {
            // It's an index, flush previous if exists and skip this line
            flushCurrentItem();
            continue; 
        }
    }

    // It's text content
    if (currentItem) {
        currentTextLines.push(line);
    }
  }

  // Flush last item
  flushCurrentItem();

  return items;
};