import { GoogleGenAI } from "@google/genai";
import { parseSRT } from '../utils/srtHelpers';
import { SubtitleItem } from '../types';

/**
 * Creates a WAV file blob from an AudioBuffer
 */
function bufferToWav(buffer: AudioBuffer): Blob {
  const numOfChan = buffer.numberOfChannels;
  const length = buffer.length * numOfChan * 2 + 44;
  const bufferOut = new ArrayBuffer(length);
  const view = new DataView(bufferOut);
  const channels = [];
  let i;
  let sample;
  let offset = 0;
  let pos = 0;

  // write WAVE header
  setUint32(0x46464952); // "RIFF"
  setUint32(length - 8); // file length - 8
  setUint32(0x45564157); // "WAVE"

  setUint32(0x20746d66); // "fmt " chunk
  setUint32(16); // length = 16
  setUint16(1); // PCM (uncompressed)
  setUint16(numOfChan);
  setUint32(buffer.sampleRate);
  setUint32(buffer.sampleRate * 2 * numOfChan); // avg. bytes/sec
  setUint16(numOfChan * 2); // block-align
  setUint16(16); // 16-bit (hardcoded in this example)

  setUint32(0x61746164); // "data" - chunk
  setUint32(length - pos - 4); // chunk length

  // write interleaved data
  for (i = 0; i < buffer.numberOfChannels; i++)
    channels.push(buffer.getChannelData(i));

  while (pos < buffer.length) {
    for (i = 0; i < numOfChan; i++) {
      // clamp
      sample = Math.max(-1, Math.min(1, channels[i][pos]));
      // scale to 16-bit signed int
      sample = (0.5 + sample < 0 ? sample * 32768 : sample * 32767) | 0;
      view.setInt16(44 + offset, sample, true);
      offset += 2;
    }
    pos++;
  }

  return new Blob([bufferOut], { type: "audio/wav" });

  function setUint16(data: number) {
    view.setUint16(pos, data, true);
    pos += 2;
  }

  function setUint32(data: number) {
    view.setUint32(pos, data, true);
    pos += 4;
  }
}

/**
 * Helper to convert blob to base64 for API transmission
 */
const blobToBase64 = (blob: Blob): Promise<string> => {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const base64String = reader.result as string;
      const base64Data = base64String.split(',')[1];
      resolve(base64Data);
    };
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
};

const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

export const analyzeAudio = async (
  file: File,
  onProgress?: (message: string) => void
): Promise<SubtitleItem[]> => {
  if (!process.env.API_KEY) {
    throw new Error("API Key is missing.");
  }

  // 1. Decode Audio using Web Audio API
  if(onProgress) onProgress("音声を読み込み中... 2%");
  await delay(100);
  const audioContext = new (window.AudioContext || (window as any).webkitAudioContext)();
  const arrayBuffer = await file.arrayBuffer();
  
  if(onProgress) onProgress("音声をデコード中... 5%");
  await delay(100);
  const originalBuffer = await audioContext.decodeAudioData(arrayBuffer);

  // 2. Resample to 16kHz Mono to reduce size
  if(onProgress) onProgress("音声データを最適化中 (16kHz Mono)... 8%");
  
  const TARGET_SAMPLE_RATE = 16000;
  const offlineCtx = new (window.OfflineAudioContext || (window as any).webkitOfflineAudioContext)(
    1, // mono
    originalBuffer.duration * TARGET_SAMPLE_RATE,
    TARGET_SAMPLE_RATE
  );
  
  const source = offlineCtx.createBufferSource();
  source.buffer = originalBuffer;
  source.connect(offlineCtx.destination);
  source.start();
  
  const processingBuffer = await offlineCtx.startRendering();

  const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
  const modelId = "gemini-flash-latest";

  // Increased chunk duration to 300s (5 minutes) because data is now lightweight
  const CHUNK_DURATION = 300; 
  const totalDuration = processingBuffer.duration;
  const chunks = Math.ceil(totalDuration / CHUNK_DURATION);
  const allSubtitles: SubtitleItem[] = [];

  // 10%まで完了済みとし、残り90%をチャンク数で割る
  const progressPerChunk = 90 / chunks;

  for (let i = 0; i < chunks; i++) {
    const startTime = i * CHUNK_DURATION;
    const endTime = Math.min((i + 1) * CHUNK_DURATION, totalDuration);
    const duration = endTime - startTime;

    // Phase 1: Chunk Preparation (Start of this chunk's progress)
    const currentBaseProgress = 10 + (i * progressPerChunk);
    if(onProgress) onProgress(`データ分割中 (${i + 1}/${chunks}) ... ${Math.floor(currentBaseProgress)}%`);
    await delay(50);

    // Create slice from the RESAMPLED buffer
    const lengthSamples = Math.floor(duration * processingBuffer.sampleRate);
    const startSample = Math.floor(startTime * processingBuffer.sampleRate);
    
    const chunkBuffer = audioContext.createBuffer(
        processingBuffer.numberOfChannels,
        lengthSamples,
        processingBuffer.sampleRate
    );

    for (let channel = 0; channel < processingBuffer.numberOfChannels; channel++) {
        const inputData = processingBuffer.getChannelData(channel);
        const outputData = chunkBuffer.getChannelData(channel);
        
        for (let j = 0; j < lengthSamples; j++) {
            if (startSample + j < inputData.length) {
                outputData[j] = inputData[startSample + j];
            }
        }
    }

    // Convert chunk to WAV
    const wavBlob = bufferToWav(chunkBuffer);
    const base64Audio = await blobToBase64(wavBlob);

    // Phase 2: Sending Request & Waiting
    // 30% point of this chunk
    const startUploadProgress = currentBaseProgress + (progressPerChunk * 0.3);
    const endUploadProgress = currentBaseProgress + (progressPerChunk * 0.8); // Target for auto-increment
    
    if(onProgress) onProgress(`AI解析を実行中 (${i + 1}/${chunks}) ... ${Math.floor(startUploadProgress)}%`);

    const prompt = `
      この音声は動画の一部（${i+1}分割目）です。
      聞こえてくる日本語の会話や歌詞を、SRT形式の字幕として書き起こしてください。
      
      【極めて重要なルール】
      1. **自然な区切り**: 歌詞のフレーズや会話の息継ぎごとに区切ってください。
         - 禁止: 8秒ごと等の機械的な等間隔分割。
         - 禁止: 文の途中で不自然に切ること。
      2. **正確なタイムスタンプ**: 
         - このファイル内での相対時間は「00:00:00,000」から始まります。正確に聞き取って時間を刻んでください。
      3. **出力形式**:
         - SRTデータのみを出力してください。挨拶やコードブロック(markdown)は不要です。
      4. **欠落防止**:
         - 小さな声や短いフレーズも漏らさず書き起こしてください。
    `;

    // APIリクエスト待機中の擬似的な進捗進行 (Auto-Increment)
    // リクエストが完了するまで、少しずつパーセンテージを進める
    let currentFakeProgress = startUploadProgress;
    const progressInterval = setInterval(() => {
        // 最大でチャンク区間の80%まで進める（残りの20%は完了時に埋める）
        if (currentFakeProgress < endUploadProgress) {
            currentFakeProgress += 0.5; // 少しずつ増やす
            if(onProgress) onProgress(`AI解析を実行中 (${i + 1}/${chunks}) ... ${Math.floor(currentFakeProgress)}%`);
        }
    }, 200);

    try {
      const response = await ai.models.generateContent({
        model: modelId,
        contents: {
          parts: [
            { inlineData: { mimeType: "audio/wav", data: base64Audio } },
            { text: prompt },
          ],
        },
        config: {
          temperature: 0.1, // High precision
        }
      });
      
      clearInterval(progressInterval); // Stop auto-increment

      // Phase 3: Response Received (Jump to 85% of chunk)
      const receivedProgress = currentBaseProgress + (progressPerChunk * 0.85);
      if(onProgress) onProgress(`字幕データを処理中 (${i + 1}/${chunks}) ... ${Math.floor(receivedProgress)}%`);
      await delay(200); // 演出用ウェイト

      const text = response.text;
      if (text) {
          // Clean text
          const cleanText = text
            .replace(/```[a-zA-Z]*\n?/g, '')
            .replace(/```/g, '')
            .trim();
          
          const chunkSubtitles = parseSRT(cleanText);
          
          // Shift timestamps and add to main list
          chunkSubtitles.forEach(sub => {
              allSubtitles.push({
                  id: crypto.randomUUID(),
                  startTime: sub.startTime + startTime,
                  endTime: sub.endTime + startTime,
                  text: sub.text
              });
          });
      }
    } catch (e) {
        clearInterval(progressInterval);
        console.error(`Error processing chunk ${i+1}:`, e);
        // エラー時も進捗を進める
        const errorProgress = currentBaseProgress + progressPerChunk;
        if(onProgress) onProgress(`解析エラー (スキップ) ... ${Math.floor(errorProgress)}%`);
    }

    // Add delay between chunks if multiple chunks exist
    if (i < chunks - 1) {
        if(onProgress) onProgress(`レート制限待機中... ${Math.floor(currentBaseProgress + progressPerChunk)}%`);
        await delay(2000); 
    }
  }
  
  // Finalize
  if(onProgress) onProgress("全工程完了！ 100%");
  
  // 重要：ユーザーが100%を見れるように確実に待機する
  await delay(1000);

  if (allSubtitles.length === 0) {
      throw new Error("字幕データを生成できませんでした。API制限の可能性があります。");
  }

  return allSubtitles;
};