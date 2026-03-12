import { SubtitleItem } from '../types';

/**
 * VAD Configuration for Local Segment Analysis
 */
const VAD_CONFIG = {
  SEARCH_WINDOW_PAD: 2.0, // 前後2.0秒まで探索範囲を拡大
  RMS_WINDOW_SIZE: 0.01,  // 10ms単位で解析（精度向上）
  
  // 閾値設定
  THRESHOLD_RATIO: 0.12,  // 最大音量の12%以上を有音とする（感度を高めに設定）
  MIN_VOLUME_ABS: 0.002,  // 絶対的なノイズフロア閾値
  
  // パディング（語頭・語尾切れ対策）
  PAD_START: 0.15,        // 開始点を0.15秒早める（アタック音対策）
  PAD_END: 0.25,          // 終了点を0.25秒伸ばす（余韻対策）
  
  // ロジック制御
  MAX_SNAP_DISTANCE: 1.0, // 元の時間から最大1秒までしか動かさない（誤爆防止）
  MIN_GAP_FILL: 0.3,      // 0.3秒未満の無音は「発話中」とみなして埋める
};

/**
 * Helpers to work with AudioBuffers
 */
async function decodeAudio(url: string): Promise<AudioBuffer> {
  const response = await fetch(url);
  const arrayBuffer = await response.arrayBuffer();
  const audioContext = new (window.AudioContext || (window as any).webkitAudioContext)();
  return await audioContext.decodeAudioData(arrayBuffer);
}

/**
 * Calculates RMS array for a specific range of audio data
 */
function calculateRMS(data: Float32Array, windowSize: number): number[] {
  const rmsProfile: number[] = [];
  for (let i = 0; i < data.length; i += windowSize) {
    let sumSq = 0;
    const end = Math.min(i + windowSize, data.length);
    const count = end - i;
    if (count === 0) break;
    
    for (let j = i; j < end; j++) {
      sumSq += data[j] * data[j];
    }
    rmsProfile.push(Math.sqrt(sumSq / count));
  }
  return rmsProfile;
}

/**
 * Aligns a single subtitle item by snapping to nearby speech edges
 */
function alignSingleSubtitle(
  subtitle: SubtitleItem,
  audioData: Float32Array,
  sampleRate: number,
  totalDuration: number
): SubtitleItem {
  
  // 1. Define Search Window (Local Area)
  const searchStart = Math.max(0, subtitle.startTime - VAD_CONFIG.SEARCH_WINDOW_PAD);
  const searchEnd = Math.min(totalDuration, subtitle.endTime + VAD_CONFIG.SEARCH_WINDOW_PAD);
  
  const startIdx = Math.floor(searchStart * sampleRate);
  const endIdx = Math.floor(searchEnd * sampleRate);
  
  if (endIdx <= startIdx) return { ...subtitle };

  // 2. Extract Data & Calculate RMS Profile
  const segmentData = audioData.subarray(startIdx, endIdx);
  const windowSizeSamples = Math.floor(sampleRate * VAD_CONFIG.RMS_WINDOW_SIZE);
  const rmsProfile = calculateRMS(segmentData, windowSizeSamples);
  
  // 3. Determine Dynamic Threshold
  let maxRms = 0;
  for (const val of rmsProfile) {
    if (val > maxRms) maxRms = val;
  }
  
  // 全体的に音が小さすぎる場合は補正しない（ノイズのみの可能性）
  if (maxRms < VAD_CONFIG.MIN_VOLUME_ABS) {
    return { ...subtitle };
  }
  
  const threshold = Math.max(maxRms * VAD_CONFIG.THRESHOLD_RATIO, VAD_CONFIG.MIN_VOLUME_ABS);

  // 4. Create Binary Speech Map & Fill Gaps
  // 各フレームが有音(true)か無音(false)か
  const isSpeech = rmsProfile.map(v => v > threshold);
  
  // 短い無音（瞬断）を埋める
  // これにより、文中の息継ぎで字幕が短く切られてしまうのを防ぐ
  const minGapFrames = Math.floor(VAD_CONFIG.MIN_GAP_FILL / VAD_CONFIG.RMS_WINDOW_SIZE);
  let gapCount = 0;
  let inGap = false;
  let gapStartIndex = -1;

  for (let i = 0; i < isSpeech.length; i++) {
    if (!isSpeech[i]) {
      if (!inGap) {
        inGap = true;
        gapStartIndex = i;
        gapCount = 1;
      } else {
        gapCount++;
      }
    } else {
      if (inGap) {
        // Gap ended. If it was short, fill it.
        if (gapCount <= minGapFrames && gapStartIndex !== -1) {
             // 直前の有音が存在する場合のみ埋める（ノイズ結合防止）
             if (gapStartIndex > 0 && isSpeech[gapStartIndex - 1]) {
                 for (let k = gapStartIndex; k < i; k++) {
                     isSpeech[k] = true;
                 }
             }
        }
        inGap = false;
      }
    }
  }

  // 5. Find Edges (Rising / Falling)
  const risingEdges: number[] = [];  // Silence -> Speech
  const fallingEdges: number[] = []; // Speech -> Silence
  
  // 最初に有音だった場合、0フレーム目を立ち上がりとする
  if (isSpeech[0]) risingEdges.push(0);

  for (let i = 1; i < isSpeech.length; i++) {
      if (isSpeech[i] && !isSpeech[i-1]) {
          risingEdges.push(i);
      }
      if (!isSpeech[i] && isSpeech[i-1]) {
          fallingEdges.push(i);
      }
  }
  
  // 最後まで有音だった場合、最後を立ち下がりとする
  if (isSpeech[isSpeech.length - 1]) fallingEdges.push(isSpeech.length);

  // 6. Snap Logic
  // RMSプロファイルのインデックスを絶対時間に変換する関数
  const idxToTime = (idx: number) => searchStart + (idx * VAD_CONFIG.RMS_WINDOW_SIZE);

  let newStartTime = subtitle.startTime;
  let newEndTime = subtitle.endTime;

  // --- Snap Start Time ---
  let minStartDist = Infinity;
  let bestStartEdge = -1;

  for (const edgeIdx of risingEdges) {
      const edgeTime = idxToTime(edgeIdx);
      // パディング分を考慮した位置と比較するべきだが、
      // ここでは純粋に「音の立ち上がり」と「現在の字幕開始」の距離を見る
      const dist = Math.abs(edgeTime - subtitle.startTime);
      
      if (dist < VAD_CONFIG.MAX_SNAP_DISTANCE && dist < minStartDist) {
          minStartDist = dist;
          bestStartEdge = edgeTime;
      }
  }

  // 良いエッジが見つかったら、そこからPAD_START分だけ前に戻す
  if (bestStartEdge !== -1) {
      newStartTime = Math.max(0, bestStartEdge - VAD_CONFIG.PAD_START);
  }

  // --- Snap End Time ---
  let minEndDist = Infinity;
  let bestEndEdge = -1;

  for (const edgeIdx of fallingEdges) {
      const edgeTime = idxToTime(edgeIdx);
      const dist = Math.abs(edgeTime - subtitle.endTime);
      
      if (dist < VAD_CONFIG.MAX_SNAP_DISTANCE && dist < minEndDist) {
          minEndDist = dist;
          bestEndEdge = edgeTime;
      }
  }

  // 良いエッジが見つかったら、そこからPAD_END分だけ後ろに伸ばす
  if (bestEndEdge !== -1) {
      newEndTime = bestEndEdge + VAD_CONFIG.PAD_END;
  }

  // 7. Validation
  // 逆転防止
  if (newStartTime >= newEndTime) {
      // 補正によって潰れてしまった場合、元の長さを維持しつつStartだけ採用（またはその逆）
      const originalDuration = subtitle.endTime - subtitle.startTime;
      if (bestStartEdge !== -1) {
          newEndTime = newStartTime + originalDuration;
      } else {
          return { ...subtitle }; // 諦めて元に戻す
      }
  }

  // 極端に短くなった場合の保護（最低0.5秒は確保など）
  if (newEndTime - newStartTime < 0.5) {
      // 元の長さの方が長ければ、元の長さをある程度復元
     if (subtitle.endTime - subtitle.startTime > 0.5) {
         // Start位置は信用して、Endを伸ばす
         newEndTime = newStartTime + (subtitle.endTime - subtitle.startTime);
     }
  }

  return {
    ...subtitle,
    startTime: newStartTime,
    endTime: newEndTime
  };
}

/**
 * Aligns subtitles to speech segments individually
 */
export const autoAlignSubtitles = async (
  audioUrl: string,
  currentSubtitles: SubtitleItem[],
  onProgress?: (msg: string) => void
): Promise<SubtitleItem[]> => {
  
  if (onProgress) onProgress("音声データをデコード中...");
  const buffer = await decodeAudio(audioUrl);
  const audioData = buffer.getChannelData(0); // Mono channel analysis
  const sampleRate = buffer.sampleRate;
  const totalDuration = buffer.duration;
  
  if (onProgress) onProgress("各字幕の波形解析と補正中...");
  
  const alignedSubtitles: SubtitleItem[] = [];
  let changedCount = 0;

  for (let i = 0; i < currentSubtitles.length; i++) {
    const sub = currentSubtitles[i];
    
    // UIをブロックしないように非同期ループ化
    if (i % 20 === 0) {
        if (onProgress) onProgress(`補正中... ${Math.floor((i / currentSubtitles.length) * 100)}%`);
        await new Promise(r => setTimeout(r, 0));
    }

    // 個別解析実行
    const newSub = alignSingleSubtitle(sub, audioData, sampleRate, totalDuration);
    
    // 変更判定 (50ms以上のズレがあればカウント)
    if (Math.abs(newSub.startTime - sub.startTime) > 0.05 || Math.abs(newSub.endTime - sub.endTime) > 0.05) {
        changedCount++;
    }
    
    alignedSubtitles.push(newSub);
  }

  // Post-processing: Overlap Cleanup
  // 補正後の重なり解消
  for (let i = 0; i < alignedSubtitles.length - 1; i++) {
      const current = alignedSubtitles[i];
      const next = alignedSubtitles[i+1];
      
      // 次の字幕の開始より、今の字幕の終了が後ろにある場合
      if (current.endTime > next.startTime) {
          // 重なり部分の中心を取る
          const mid = (current.endTime + next.startTime) / 2;
          
          // 最小ギャップを確保 (0.05s)
          current.endTime = Math.max(current.startTime, mid - 0.025);
          next.startTime = Math.min(next.endTime, mid + 0.025);
      }
  }

  console.log(`Auto-aligned ${changedCount} / ${alignedSubtitles.length} subtitles.`);
  return alignedSubtitles;
};