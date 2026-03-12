export interface SubtitleItem {
  id: string;
  startTime: number; // in seconds
  endTime: number; // in seconds
  text: string;
}

export enum ProcessingStatus {
  IDLE = 'IDLE',
  UPLOADING = 'UPLOADING',
  ANALYZING = 'ANALYZING',
  COMPLETED = 'COMPLETED',
  ERROR = 'ERROR',
}

export interface AudioMetadata {
  name: string;
  duration: number;
  url: string;
  mimeType: string;
}
