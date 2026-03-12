import React, { useEffect, useRef, useState, useCallback } from 'react';
import WaveSurfer from 'wavesurfer.js';
import TimelinePlugin from 'wavesurfer.js/dist/plugins/timeline.esm.js';
import ZoomPlugin from 'wavesurfer.js/dist/plugins/zoom.esm.js';
import { SubtitleItem } from '../types';
import { Play, Pause, ZoomIn, ZoomOut, Type, Music, GripVertical, Volume2, VolumeX } from 'lucide-react';

interface WaveformEditorProps {
  audioUrl: string;
  subtitles: SubtitleItem[];
  onSubtitlesChange: (subtitles: SubtitleItem[]) => void;
  onTimeUpdate: (time: number) => void;
}

// Drag Types
type DragMode = 'move' | 'resize-left' | 'resize-right' | 'seek';
interface DragState {
  id: string;
  mode: DragMode;
  startX: number;
  initialStartTime: number;
  initialEndTime: number;
  wasPlaying: boolean;
}

const WaveformEditor: React.FC<WaveformEditorProps> = ({
  audioUrl,
  subtitles,
  onSubtitlesChange,
  onTimeUpdate,
}) => {
  // Refs
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const contentWrapperRef = useRef<HTMLDivElement>(null);
  const audioContainerRef = useRef<HTMLDivElement>(null);
  const timelineContainerRef = useRef<HTMLDivElement>(null);
  const wavesurferRef = useRef<WaveSurfer | null>(null);
  const playheadRef = useRef<HTMLDivElement>(null);
  
  // State
  const [isPlaying, setIsPlaying] = useState(false);
  const [isReady, setIsReady] = useState(false);
  const [zoom, setZoom] = useState(100); 
  const [duration, setDuration] = useState(0);
  const [currentTime, setCurrentTime] = useState(0);
  const [volume, setVolume] = useState(1.0);
  const [isMuted, setIsMuted] = useState(false);
  
  // Dragging State
  const [dragState, setDragState] = useState<DragState | null>(null);

  // Constants
  const HEADER_WIDTH = 100;
  const SUBTITLE_HEIGHT = 110;
  const AUDIO_HEIGHT = 128;
  const TIMELINE_HEIGHT = 28;
  
  // 余白（パディング）を追加して、計算誤差による描画切れを防ぐ
  const PADDING_RIGHT = 300; 
  const totalContentWidth = Math.max(duration * zoom, 100) + PADDING_RIGHT;

  const formatDisplayTime = (time: number) => {
    const mins = Math.floor(time / 60);
    const secs = Math.floor(time % 60);
    const ms = Math.floor((time % 1) * 100);
    return `${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}.${ms.toString().padStart(2, '0')}`;
  };

  useEffect(() => {
    if (!audioContainerRef.current || !timelineContainerRef.current) return;

    setIsReady(false);
    setIsPlaying(false);

    // Create WaveSurfer instance
    const ws = WaveSurfer.create({
      container: audioContainerRef.current,
      waveColor: '#f472b6', // Pink-400
      progressColor: '#be185d', // Pink-700
      cursorColor: 'transparent',
      cursorWidth: 0,
      height: AUDIO_HEIGHT,
      minPxPerSec: zoom, 
      fillParent: false, 
      autoScroll: false, 
      autoCenter: false,
      interact: false, // We handle interaction manually for better sync
      hideScrollbar: true,
      pixelRatio: 1, 
      plugins: [
        TimelinePlugin.create({
          container: timelineContainerRef.current,
          primaryLabelInterval: 5,
          secondaryLabelInterval: 1,
          style: {
            color: '#374151',
            fontSize: '11px',
            fontFamily: 'monospace',
            fontWeight: 'bold',
          },
        }),
        ZoomPlugin.create(),
      ],
    } as any);

    wavesurferRef.current = ws;

    ws.on('ready', () => {
      setIsReady(true);
      const d = ws.getDuration();
      setDuration(d);
      ws.setVolume(isMuted ? 0 : volume);
      // No need to call zoom here as minPxPerSec is set in create
    });

    ws.on('decode', (d) => {
        setDuration(d);
    });

    ws.on('play', () => setIsPlaying(true));
    ws.on('pause', () => setIsPlaying(false));
    
    ws.on('timeupdate', (t) => {
      setCurrentTime(t);
      onTimeUpdate(t);

      if (playheadRef.current) {
        playheadRef.current.style.left = `${t * zoom}px`;
      }

      // Auto scroll logic during playback
      if (ws.isPlaying() && scrollContainerRef.current) {
        const container = scrollContainerRef.current;
        const currentPosPx = t * zoom;
        const containerWidth = container.clientWidth;
        const scrollLeft = container.scrollLeft;

        // Keep playhead within view logic
        if (currentPosPx > scrollLeft + containerWidth - 50) {
          container.scrollLeft = currentPosPx - (containerWidth * 0.1); 
        } 
        else if (currentPosPx < scrollLeft) {
            container.scrollLeft = currentPosPx - (containerWidth * 0.1);
        }
      }
    });

    ws.load(audioUrl).catch((err) => {
      if (err.name === 'AbortError' || err.message === 'signal is aborted without reason') {
        console.log('WaveSurfer load aborted');
      } else {
        console.error(err);
      }
    });

    return () => {
      ws.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [audioUrl]);

  // Handle Zoom changes & Resize Observer
  useEffect(() => {
    if (!wavesurferRef.current) return;

    if (isReady) {
        wavesurferRef.current.zoom(zoom);
        // Playhead sync
        const t = wavesurferRef.current.getCurrentTime();
        if (playheadRef.current) {
            playheadRef.current.style.left = `${t * zoom}px`;
        }
    }
  }, [zoom, isReady]);

  // Handle Volume changes
  useEffect(() => {
    if (wavesurferRef.current) {
        wavesurferRef.current.setVolume(isMuted ? 0 : volume);
    }
  }, [volume, isMuted]);

  // --- Drag & Drop Logic ---
  const handleDragStart = (e: React.MouseEvent, id: string, mode: DragMode, startTime: number, endTime: number) => {
    e.stopPropagation();
    e.preventDefault();
    
    // Check if playing and pause if necessary to prevent stuttering and sync issues
    let wasPlaying = false;
    if (wavesurferRef.current) {
        wasPlaying = wavesurferRef.current.isPlaying();
        if (wasPlaying) {
            wavesurferRef.current.pause();
        }
    }
    
    setDragState({
        id,
        mode,
        startX: e.clientX,
        initialStartTime: startTime,
        initialEndTime: endTime,
        wasPlaying
    });
  };

  const handleGlobalMouseMove = useCallback((e: MouseEvent) => {
    if (!dragState) return;

    const deltaPixels = e.clientX - dragState.startX;
    const deltaTime = deltaPixels / zoom;

    // Handle Seek Dragging
    if (dragState.mode === 'seek') {
        let newTime = dragState.initialStartTime + deltaTime;
        newTime = Math.max(0, Math.min(newTime, duration));
        
        if (wavesurferRef.current) {
            wavesurferRef.current.setTime(newTime);
        }
        return; 
    }

    // Handle Subtitle Dragging
    onSubtitlesChange(subtitles.map(sub => {
        if (sub.id !== dragState.id) return sub;

        let newStart = sub.startTime;
        let newEnd = sub.endTime;

        if (dragState.mode === 'move') {
            newStart = Math.max(0, dragState.initialStartTime + deltaTime);
            newEnd = Math.max(0, dragState.initialEndTime + deltaTime);
            if (newEnd > duration && duration > 0) {
                const len = newEnd - newStart;
                newEnd = duration;
                newStart = duration - len;
            }
        } else if (dragState.mode === 'resize-left') {
            newStart = Math.min(dragState.initialStartTime + deltaTime, dragState.initialEndTime - 0.2);
            newStart = Math.max(0, newStart);
        } else if (dragState.mode === 'resize-right') {
            newEnd = Math.max(dragState.initialEndTime + deltaTime, dragState.initialStartTime + 0.2);
            if (duration > 0) newEnd = Math.min(newEnd, duration);
        }

        return { ...sub, startTime: newStart, endTime: newEnd };
    }));

  }, [dragState, subtitles, zoom, duration, onSubtitlesChange]);

  const handleGlobalMouseUp = useCallback(() => {
    if (dragState && wavesurferRef.current) {
        // Resume playback if it was playing before drag
        if (dragState.wasPlaying) {
            wavesurferRef.current.play();
        }
    }
    setDragState(null);
  }, [dragState]);

  useEffect(() => {
    if (dragState) {
        window.addEventListener('mousemove', handleGlobalMouseMove);
        window.addEventListener('mouseup', handleGlobalMouseUp);
    } else {
        window.removeEventListener('mousemove', handleGlobalMouseMove);
        window.removeEventListener('mouseup', handleGlobalMouseUp);
    }
    return () => {
        window.removeEventListener('mousemove', handleGlobalMouseMove);
        window.removeEventListener('mouseup', handleGlobalMouseUp);
    };
  }, [dragState, handleGlobalMouseMove, handleGlobalMouseUp]);

  // --- Interactions ---
  const handlePlayPause = useCallback(() => {
    if (wavesurferRef.current && isReady) {
      wavesurferRef.current.playPause();
    }
  }, [isReady]);

  const handleZoomIn = () => setZoom(prev => Math.min(prev + 20, 500));
  const handleZoomOut = () => setZoom(prev => Math.max(prev - 20, 10));

  // トラック上でマウスダウンした時の処理（即時シーク＆ドラッグ開始）
  const handleTrackMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
      // 左クリック以外は無視
      if (e.button !== 0) return;

      const rect = e.currentTarget.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const clickedTime = Math.max(0, Math.min(x / zoom, duration));
      
      // UIを即座に更新
      if (wavesurferRef.current) {
          wavesurferRef.current.setTime(clickedTime);
          if (playheadRef.current) {
            playheadRef.current.style.left = `${clickedTime * zoom}px`;
          }
      }

      // シークバーのドラッグとして処理を開始（再生中なら一時停止などの管理も行う）
      handleDragStart(e, 'playhead', 'seek', clickedTime, 0);
  };

  return (
    <div className="w-full flex flex-col bg-white border-2 border-black rounded-xl overflow-hidden select-none shadow-[6px_6px_0px_0px_rgba(0,0,0,1)]">
      
      {/* 1. Control Toolbar */}
      <div className="flex items-center justify-between px-4 py-2 bg-purple-100 border-b-2 border-black z-20 relative">
        <div className="flex items-center gap-6">
          <div className="flex items-center gap-4">
            <button
                onClick={handlePlayPause}
                disabled={!isReady}
                className={`w-12 h-12 flex items-center justify-center rounded-full text-white border-2 border-black shadow-[2px_2px_0px_0px_rgba(0,0,0,1)] transition-all ${
                !isReady 
                    ? 'bg-gray-400 cursor-not-allowed opacity-50' 
                    : 'bg-green-500 hover:bg-green-400 active:translate-x-[2px] active:translate-y-[2px] active:shadow-none'
                }`}
            >
                {isPlaying ? <Pause size={24} fill="currentColor" /> : <Play size={24} fill="currentColor" className="ml-1" />}
            </button>
            <div className="flex flex-col min-w-[100px]">
                <span className="text-[10px] text-purple-800 font-black tracking-widest uppercase mb-0.5">Time</span>
                <span className="text-xl font-mono font-bold text-black tabular-nums tracking-tighter">
                    {formatDisplayTime(currentTime)}
                    <span className="text-gray-400 mx-1 text-sm font-normal">/</span>
                    <span className="text-gray-500 text-base">{formatDisplayTime(duration)}</span>
                </span>
            </div>
          </div>
        </div>

        <div className="flex items-center gap-6">
          {/* Volume Control */}
          <div className="hidden sm:flex items-center gap-2 bg-white p-1 px-3 rounded-full border-2 border-black shadow-sm">
             <button onClick={() => setIsMuted(!isMuted)} className="text-gray-600 hover:text-black transition-colors">
                {isMuted ? <VolumeX size={18} /> : <Volume2 size={18} />}
             </button>
             <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={isMuted ? 0 : volume}
                onChange={(e) => {
                    setVolume(Number(e.target.value));
                    if (Number(e.target.value) > 0 && isMuted) setIsMuted(false);
                }}
                className="w-20 h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer accent-purple-500"
             />
          </div>

          {/* Zoom Control */}
          <div className="flex items-center gap-3 bg-white p-1.5 rounded-full border-2 border-black shadow-sm">
            <button onClick={handleZoomOut} className="p-1 text-gray-600 hover:text-black hover:bg-gray-100 rounded-full">
                <ZoomOut size={18} />
            </button>
            <input
                type="range"
                min="10"
                max="300"
                value={zoom}
                onChange={(e) => setZoom(Number(e.target.value))}
                className="w-24 h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer accent-pink-500"
            />
            <button onClick={handleZoomIn} className="p-1 text-gray-600 hover:text-black hover:bg-gray-100 rounded-full">
                <ZoomIn size={18} />
            </button>
            <span className="text-xs font-bold text-gray-600 min-w-[36px] text-right">
                {zoom}%
            </span>
          </div>
        </div>
      </div>

      {/* 2. Main Timeline Area */}
      <div className="flex relative bg-white h-full">
        
        {/* LEFT: Track Headers (Sticky) */}
        <div className="flex-shrink-0 flex flex-col border-r-2 border-black bg-gray-50 z-30" style={{ width: HEADER_WIDTH }}>
           {/* Timeline Header Spacer */}
           <div className="border-b-2 border-black bg-white" style={{ height: TIMELINE_HEIGHT }}></div>
           
           {/* Subtitle Header */}
           <div className="border-b-2 border-black flex flex-col items-center justify-center relative bg-orange-100" 
                style={{ height: SUBTITLE_HEIGHT }}>
                <div className="flex flex-col items-center gap-1">
                    <div className="bg-orange-500 text-white p-1 rounded-md border border-black shadow-[1px_1px_0px_0px_rgba(0,0,0,1)]">
                       <Type size={16} />
                    </div>
                    <span className="text-[9px] text-gray-800 font-bold uppercase tracking-widest mt-1">TEXT</span>
                </div>
           </div>

           {/* Audio Header */}
           <div className="flex flex-col items-center justify-center relative bg-purple-100" 
                style={{ height: AUDIO_HEIGHT }}>
                <div className="flex flex-col items-center gap-1">
                    <div className="bg-purple-500 text-white p-1 rounded-md border border-black shadow-[1px_1px_0px_0px_rgba(0,0,0,1)]">
                        <Music size={16} />
                    </div>
                    <span className="text-[9px] text-gray-800 font-bold uppercase tracking-widest mt-1">AUDIO</span>
                </div>
           </div>
        </div>

        {/* RIGHT: Master Scroll Container */}
        <div 
            ref={scrollContainerRef}
            className="flex-1 relative overflow-x-auto overflow-y-hidden bg-white"
        >
            {/* Inner Content Wrapper */}
            <div 
                ref={contentWrapperRef}
                style={{ width: totalContentWidth }} 
                className="relative flex flex-col h-full"
            >
                {/* Global Playhead (Neon Blue Line) */}
                <div 
                    ref={playheadRef}
                    className="absolute top-0 bottom-0 z-50 pointer-events-none"
                    style={{ left: 0, height: '100%' }}
                >
                    {/* Handle */}
                    <div 
                        className="absolute -top-3 left-0 -translate-x-1/2 w-6 h-6 cursor-ew-resize pointer-events-auto z-50 text-blue-600 hover:text-blue-500 transition-transform hover:scale-125 flex items-start justify-center drop-shadow-md"
                        onMouseDown={(e) => handleDragStart(e, 'playhead', 'seek', currentTime, 0)}
                    >
                         <svg viewBox="0 0 24 24" fill="currentColor" stroke="black" strokeWidth="2" className="w-full h-full">
                            <path d="M4 0 L20 0 L12 12 Z" />
                         </svg>
                    </div>

                    {/* Line */}
                    <div className="absolute top-0 bottom-0 left-0 -translate-x-1/2 w-0.5 bg-blue-500 shadow-[0_0_4px_rgba(59,130,246,0.8)]" />
                </div>

                {/* A. Ruler (Timeline) */}
                <div 
                    ref={timelineContainerRef} 
                    className="bg-white border-b-2 border-black cursor-pointer"
                    style={{ height: TIMELINE_HEIGHT, width: duration * zoom }}
                    onMouseDown={handleTrackMouseDown}
                />

                {/* B. Subtitle Track */}
                <div 
                    className="bg-orange-50/50 border-b-2 border-black relative cursor-text group"
                    style={{ height: SUBTITLE_HEIGHT, width: duration * zoom }}
                    onMouseDown={handleTrackMouseDown}
                >
                    {/* Grid Background */}
                    <div className="absolute inset-0 opacity-20 pointer-events-none" 
                         style={{ backgroundImage: 'linear-gradient(90deg, #fb923c 1px, transparent 1px)', backgroundSize: '50px 100%' }}>
                    </div>
                    
                    {/* Subtitles Items */}
                    {subtitles.map((sub) => {
                        const isDragging = dragState?.id === sub.id;
                        const width = (sub.endTime - sub.startTime) * zoom;
                        const left = sub.startTime * zoom;
                        
                        return (
                            <div
                                key={sub.id}
                                className={`absolute top-2 bottom-2 rounded-lg border-2 flex flex-col overflow-hidden select-none transition-all
                                    ${isDragging 
                                        ? 'bg-yellow-300 border-black z-40 shadow-[4px_4px_0px_0px_rgba(0,0,0,1)]' 
                                        : 'bg-white border-black hover:bg-yellow-50 shadow-[2px_2px_0px_0px_rgba(0,0,0,1)] z-20'
                                    }`}
                                style={{
                                    left: `${left}px`,
                                    width: `${Math.max(width, 10)}px`,
                                    cursor: 'grab'
                                }}
                                onMouseDown={(e) => handleDragStart(e, sub.id, 'move', sub.startTime, sub.endTime)}
                                onClick={(e) => e.stopPropagation()} 
                            >
                                {/* Left Handle */}
                                <div 
                                    className="absolute left-0 top-0 bottom-0 w-3 cursor-w-resize z-30 opacity-0 hover:opacity-100 bg-blue-400/30 transition-opacity"
                                    onMouseDown={(e) => handleDragStart(e, sub.id, 'resize-left', sub.startTime, sub.endTime)}
                                />
                                
                                {/* Right Handle */}
                                <div 
                                    className="absolute right-0 top-0 bottom-0 w-3 cursor-e-resize z-30 opacity-0 hover:opacity-100 bg-blue-400/30 transition-opacity"
                                    onMouseDown={(e) => handleDragStart(e, sub.id, 'resize-right', sub.startTime, sub.endTime)}
                                />

                                <div className="flex-1 p-1 overflow-hidden pointer-events-none flex items-center justify-center">
                                    <p className="text-[11px] leading-tight text-gray-800 font-bold whitespace-nowrap overflow-hidden text-ellipsis px-1">
                                        {sub.text}
                                    </p>
                                </div>
                                <div className="h-3 bg-gray-100 mx-1 mb-1 rounded flex items-center justify-center opacity-50 border border-gray-300">
                                   <GripVertical size={10} className="text-gray-400" />
                                </div>
                            </div>
                        );
                    })}
                </div>

                {/* C. Audio Track (WaveSurfer) */}
                <div 
                    className="bg-white relative cursor-pointer"
                    style={{ height: AUDIO_HEIGHT, width: duration * zoom }}
                    onMouseDown={handleTrackMouseDown}
                >
                    <div ref={audioContainerRef} className="w-full h-full block pointer-events-none" />
                </div>

            </div>
        </div>
      </div>
    </div>
  );
};

export default WaveformEditor;