import React, { useState, useRef, useCallback } from 'react';
import { Upload, FileAudio, Wand2, Download, AlertCircle, Loader2, Music, Sparkles } from 'lucide-react';
import { SubtitleItem, ProcessingStatus, AudioMetadata } from './types';
import { analyzeAudio } from './services/geminiService';
import { autoAlignSubtitles } from './services/vadService';
import { generateSRT } from './utils/srtHelpers';
import WaveformEditor from './components/WaveformEditor';
import SubtitleList from './components/SubtitleList';

// Helper to extract percentage from progress string
const getProgressPercentage = (progressStr: string): number => {
  // 1. Try to find explicit percentage first (e.g., "10%")
  const percentMatch = progressStr.match(/(\d+)%/);
  if (percentMatch) {
    const p = parseInt(percentMatch[1], 10);
    return Math.min(Math.max(p, 0), 100);
  }

  // 2. Regex to match "1/5" or similar patterns inside the string
  const match = progressStr.match(/(\d+)\/(\d+)/);
  if (match) {
    const current = parseInt(match[1], 10);
    const total = parseInt(match[2], 10);
    if (total > 0) return Math.min(Math.round((current / total) * 100), 100);
  }
  return 0;
};

const App: React.FC = () => {
  const [audioFile, setAudioFile] = useState<File | null>(null);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [audioMeta, setAudioMeta] = useState<AudioMetadata | null>(null);
  const [subtitles, setSubtitles] = useState<SubtitleItem[]>([]);
  const [status, setStatus] = useState<ProcessingStatus>(ProcessingStatus.IDLE);
  const [progress, setProgress] = useState<string>("");
  const [currentTime, setCurrentTime] = useState(0);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [isAligning, setIsAligning] = useState(false);
  const [isDragging, setIsDragging] = useState(false);

  const processFile = (file: File) => {
    const validMime = file.type.startsWith('audio/') || file.type.startsWith('video/');
    // 拡張子によるチェックも併用（MIMEタイプが空の場合があるため）
    const validExt = /\.(mp3|wav|ogg|m4a|mp4|webm|flac|aac|wma)$/i.test(file.name);

    if (!validMime && !validExt) {
      setErrorMsg('Please upload a valid audio file (MP3, WAV, etc).');
      return;
    }

    if (file.size > 100 * 1024 * 1024) { // 100MB limit
      setErrorMsg('File size exceeds 100MB limit.');
      return;
    }
    
    if (audioUrl) URL.revokeObjectURL(audioUrl);

    const url = URL.createObjectURL(file);
    setAudioFile(file);
    setAudioUrl(url);
    setAudioMeta({
      name: file.name,
      duration: 0,
      url: url,
      mimeType: file.type,
    });
    setSubtitles([]);
    setStatus(ProcessingStatus.IDLE);
    setErrorMsg(null);
    setProgress("");
  };

  const handleFileChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      processFile(file);
    }
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  };

  const handleDragLeave = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    const file = e.dataTransfer.files?.[0];
    if (file) {
      processFile(file);
    }
  };

  const handleAnalyze = async () => {
    if (!audioFile) return;

    setStatus(ProcessingStatus.ANALYZING);
    setErrorMsg(null);
    setProgress("準備中...");

    try {
      const generatedSubtitles = await analyzeAudio(audioFile, (msg) => setProgress(msg));
      
      if (generatedSubtitles.length === 0) {
        throw new Error("字幕が生成されませんでした。音声が認識できなかった可能性があります。");
      }

      setSubtitles(generatedSubtitles);
      
      // 念のためUI側でも少し待ってから完了ステータスへ移行
      await new Promise(r => setTimeout(r, 500));
      setStatus(ProcessingStatus.COMPLETED);
    } catch (err: any) {
      console.error(err);
      setErrorMsg(err.message || "Failed to analyze audio. Please check your API Key and try again.");
      setStatus(ProcessingStatus.ERROR);
    } finally {
      setProgress("");
    }
  };

  const handleAutoAlign = async () => {
    if (!audioUrl || subtitles.length === 0) return;
    
    setIsAligning(true);
    setProgress("波形解析中...");
    
    try {
        const aligned = await autoAlignSubtitles(audioUrl, subtitles, (msg) => setProgress(msg));
        setSubtitles(aligned);
    } catch (e: any) {
        console.error("Alignment failed", e);
        setErrorMsg("波形補正に失敗しました: " + e.message);
    } finally {
        setIsAligning(false);
        setProgress("");
    }
  };

  const handleExport = () => {
    const srtContent = generateSRT(subtitles);
    const blob = new Blob([srtContent], { type: 'text/srt' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = audioMeta ? `${audioMeta.name.replace(/\.[^/.]+$/, "")}.srt` : 'subtitles.srt';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const handleSubtitleUpdate = useCallback((updatedSubtitles: SubtitleItem[]) => {
    setSubtitles(updatedSubtitles);
  }, []);

  const handleTextEdit = useCallback((id: string, newText: string) => {
    setSubtitles(prev => prev.map(sub => sub.id === id ? { ...sub, text: newText } : sub));
  }, []);

  const handleDeleteSubtitle = useCallback((id: string) => {
    setSubtitles(prev => prev.filter(sub => sub.id !== id));
  }, []);

  return (
    <div className="min-h-screen text-gray-800 flex flex-col font-sans bg-yellow-50 selection:bg-pink-300 selection:text-pink-900">
      {/* Header */}
      <header className="bg-white border-b-4 border-black p-4 sticky top-0 z-50">
        <div className="max-w-7xl mx-auto flex justify-between items-center">
          <div className="flex items-center space-x-3 group cursor-pointer" onClick={() => window.location.reload()}>
            <div className="w-10 h-10 bg-violet-500 rounded-lg flex items-center justify-center border-2 border-black shadow-[4px_4px_0px_0px_rgba(0,0,0,1)] group-hover:translate-x-[2px] group-hover:translate-y-[2px] group-hover:shadow-[2px_2px_0px_0px_rgba(0,0,0,1)] transition-all">
                <FileAudio size={24} className="text-white" />
            </div>
            <h1 className="text-2xl font-black italic tracking-tighter text-black">
              AI <span className="text-violet-600">Subtitle</span> Studio
            </h1>
          </div>
          
          <div className="flex items-center space-x-4">
             {audioFile && (
                <div className="hidden sm:flex items-center gap-2 bg-blue-100 px-3 py-1 rounded-full border-2 border-black">
                   <Music size={14} className="text-blue-600"/>
                   <span className="text-sm font-bold text-blue-900 max-w-[150px] truncate">
                      {audioFile.name}
                   </span>
                </div>
             )}
            <button
              onClick={handleExport}
              disabled={subtitles.length === 0}
              className={`flex items-center space-x-2 px-6 py-2 rounded-lg font-bold border-2 border-black transition-all transform active:scale-95 ${
                subtitles.length > 0
                  ? 'bg-green-400 hover:bg-green-300 text-black shadow-[4px_4px_0px_0px_rgba(0,0,0,1)] hover:shadow-[6px_6px_0px_0px_rgba(0,0,0,1)]'
                  : 'bg-gray-200 text-gray-400 border-gray-400 cursor-not-allowed shadow-none'
              }`}
            >
              <Download size={20} />
              <span>EXPORT .SRT</span>
            </button>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="flex-1 max-w-7xl w-full mx-auto p-4 sm:p-6 flex flex-col gap-6">
        
        {/* Error Message */}
        {errorMsg && (
          <div className="bg-red-100 border-2 border-black text-red-800 p-4 rounded-xl shadow-[4px_4px_0px_0px_rgba(239,68,68,1)] flex items-center space-x-3 animate-in fade-in slide-in-from-top-2">
            <AlertCircle size={24} className="text-red-600" />
            <span className="font-bold">{errorMsg}</span>
          </div>
        )}

        {/* Upload Section (If no file) */}
        {!audioUrl && (
          <div className="flex-1 flex items-center justify-center min-h-[400px]">
            <label 
              className={`group relative flex flex-col items-center justify-center w-full max-w-2xl h-80 border-4 border-dashed rounded-3xl cursor-pointer transition-all duration-300 ${
                isDragging 
                  ? 'border-violet-500 bg-violet-100 scale-105' 
                  : 'border-gray-300 bg-white hover:border-violet-500 hover:bg-violet-50'
              }`}
              onDragOver={handleDragOver}
              onDragLeave={handleDragLeave}
              onDrop={handleDrop}
            >
              <div className="flex flex-col items-center justify-center pt-5 pb-6 pointer-events-none">
                <div className={`p-6 rounded-2xl border-2 border-black shadow-[4px_4px_0px_0px_rgba(0,0,0,1)] mb-6 transition-transform duration-300 ${
                    isDragging ? 'bg-violet-400 scale-110 rotate-3' : 'bg-yellow-300 group-hover:scale-110 group-hover:rotate-3'
                }`}>
                   <Upload className={`w-12 h-12 text-black ${isDragging ? 'text-white' : ''}`} />
                </div>
                <p className="mb-2 text-3xl font-black text-gray-800 group-hover:text-violet-600 transition-colors">
                    {isDragging ? 'DROP FILE HERE' : 'UPLOAD AUDIO'}
                </p>
                <p className="text-lg font-bold text-gray-500 bg-gray-100 px-4 py-1 rounded-full border-2 border-transparent group-hover:border-black group-hover:bg-white transition-all">
                    MP3, WAV (Max 100MB)
                </p>
              </div>
              <input type="file" className="hidden" accept="audio/*, .mp3, .wav, .m4a, .ogg" onChange={handleFileChange} />
            </label>
          </div>
        )}

        {/* Editor Interface */}
        {audioUrl && (
          <div className="flex flex-col h-[calc(100vh-140px)] gap-6">
            
            {/* Top Section: Preview & List */}
            <div className="flex flex-col lg:flex-row gap-6 flex-1 min-h-0">
                {/* Left: Video Preview Style Display */}
                <div className="flex-1 flex flex-col bg-white rounded-xl border-2 border-black shadow-[6px_6px_0px_0px_rgba(0,0,0,1)] overflow-hidden">
                    <div className="flex items-center justify-between p-3 border-b-2 border-black bg-pink-100">
                        <h2 className="text-sm font-black text-black flex items-center gap-2 uppercase tracking-wider">
                            <span className="w-3 h-3 rounded-full bg-red-500 border border-black animate-pulse"></span>
                            Live Preview
                        </h2>
                        {status !== ProcessingStatus.COMPLETED && (
                             <button
                             onClick={handleAnalyze}
                             disabled={status === ProcessingStatus.ANALYZING}
                             className={`flex items-center space-x-2 px-4 py-1.5 rounded-lg text-sm font-bold text-black border-2 border-black transition-all ${
                               status === ProcessingStatus.ANALYZING
                                 ? 'bg-yellow-200 cursor-wait opacity-80'
                                 : 'bg-yellow-400 hover:bg-yellow-300 shadow-[2px_2px_0px_0px_rgba(0,0,0,1)] hover:translate-x-[1px] hover:translate-y-[1px] hover:shadow-none active:translate-x-[2px] active:translate-y-[2px]'
                             }`}
                           >
                             {status === ProcessingStatus.ANALYZING ? (
                               <>
                                 <Loader2 className="animate-spin" size={16} />
                                 <span>GENERATING...</span>
                               </>
                             ) : (
                               <>
                                 <Sparkles size={16} />
                                 <span>AUTO GENERATE</span>
                               </>
                             )}
                           </button>
                        )}
                    </div>
                    
                    <div className="flex-1 bg-gray-900 relative flex items-center justify-center overflow-hidden group">
                        {/* Background Grid Pattern */}
                        <div className="absolute inset-0 opacity-20" 
                             style={{ backgroundImage: 'linear-gradient(#4b5563 1px, transparent 1px), linear-gradient(90deg, #4b5563 1px, transparent 1px)', backgroundSize: '40px 40px' }}>
                        </div>
                        
                        {/* Content Area */}
                        {status === ProcessingStatus.ANALYZING ? (
                            <div className="z-20 flex flex-col items-center justify-center space-y-4 p-8 w-full max-w-md animate-in fade-in zoom-in duration-300">
                                {/* Animated Icon */}
                                <div className="relative">
                                    <div className="absolute inset-0 bg-pink-500 rounded-full blur-xl opacity-50 animate-pulse"></div>
                                    <Loader2 size={64} className="text-pink-400 animate-spin relative z-10" />
                                </div>
                                
                                {/* Status Text */}
                                <div className="text-center space-y-2 w-full">
                                    <p className="text-white text-xl font-bold tracking-wider animate-pulse">
                                        ANALYZING...
                                    </p>
                                    <p className="text-gray-400 text-sm font-mono truncate px-4">
                                        {progress}
                                    </p>
                                </div>

                                {/* Progress Bar */}
                                {(() => {
                                    const percent = getProgressPercentage(progress);
                                    return (
                                        <div className="w-full bg-gray-800 rounded-full h-4 border-2 border-gray-700 overflow-hidden relative mt-2 shadow-inner">
                                            <div 
                                                className="h-full bg-gradient-to-r from-pink-500 to-violet-500 transition-all duration-500 ease-out flex items-center justify-end px-2"
                                                style={{ width: `${percent}%` }}
                                            >
                                                {percent > 5 && <span className="text-[9px] font-bold text-white drop-shadow-md">{percent}%</span>}
                                            </div>
                                            
                                            {/* Striped overlay */}
                                            <div className="absolute inset-0 opacity-20 pointer-events-none" 
                                                style={{ backgroundImage: 'linear-gradient(45deg,rgba(255,255,255,.15) 25%,transparent 25%,transparent 50%,rgba(255,255,255,.15) 50%,rgba(255,255,255,.15) 75%,transparent 75%,transparent)', backgroundSize: '1rem 1rem' }} 
                                            />
                                        </div>
                                    );
                                })()}
                            </div>
                        ) : (
                            <div className="text-center px-8 sm:px-16 z-10 w-full">
                                <p className="text-3xl md:text-4xl lg:text-5xl font-black text-white drop-shadow-[4px_4px_0px_#ec4899] stroke-black leading-tight tracking-wide transition-all duration-100 select-text">
                                    {subtitles.find(s => currentTime >= s.startTime && currentTime <= s.endTime)?.text || ""}
                                </p>
                            </div>
                        )}
                    </div>
                </div>

                {/* Right: Subtitle List */}
                <div className="w-full lg:w-96 flex-none h-80 lg:h-full">
                    <SubtitleList
                        subtitles={subtitles}
                        currentTime={currentTime}
                        onUpdateSubtitle={handleTextEdit}
                        onDeleteSubtitle={handleDeleteSubtitle}
                        onAutoAlign={handleAutoAlign}
                        isAligning={isAligning}
                    />
                </div>
            </div>

            {/* Bottom Section: Timeline Editor */}
            <div className="flex-none">
                 <WaveformEditor
                  audioUrl={audioUrl}
                  subtitles={subtitles}
                  onSubtitlesChange={handleSubtitleUpdate}
                  onTimeUpdate={setCurrentTime}
                />
            </div>
          </div>
        )}
      </main>
    </div>
  );
};

export default App;