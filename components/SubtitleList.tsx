import React, { useRef, useEffect } from 'react';
import { SubtitleItem } from '../types';
import { formatTime } from '../utils/srtHelpers';
import { Trash2, Clock, Wand2, Type } from 'lucide-react';

interface SubtitleListProps {
  subtitles: SubtitleItem[];
  currentTime: number;
  onUpdateSubtitle: (id: string, newText: string) => void;
  onDeleteSubtitle: (id: string) => void;
  onAutoAlign?: () => void;
  isAligning?: boolean;
}

const SubtitleList: React.FC<SubtitleListProps> = ({
  subtitles,
  currentTime,
  onUpdateSubtitle,
  onDeleteSubtitle,
  onAutoAlign,
  isAligning = false,
}) => {
  const activeRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (activeRef.current) {
      activeRef.current.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  }, [currentTime]); 

  return (
    <div className="flex flex-col h-full bg-white rounded-xl border-2 border-black shadow-[6px_6px_0px_0px_rgba(0,0,0,1)] overflow-hidden">
        <div className="p-3 bg-cyan-100 border-b-2 border-black font-bold text-gray-800 flex justify-between items-center">
            <div className="flex items-center gap-2">
                <Type size={18} className="text-black" />
                <span>SUBTITLES</span>
            </div>
            <div className="flex items-center gap-2">
                {onAutoAlign && subtitles.length > 0 && (
                     <button 
                        onClick={onAutoAlign}
                        disabled={isAligning}
                        className="flex items-center gap-1 text-[10px] font-bold bg-violet-500 hover:bg-violet-400 disabled:bg-gray-400 text-white px-2 py-1 rounded border-2 border-black shadow-[2px_2px_0px_0px_rgba(0,0,0,1)] active:shadow-none active:translate-x-[1px] active:translate-y-[1px] transition-all"
                        title="VADで波形に合わせてタイミングを自動補正"
                     >
                        <Wand2 size={10} className={isAligning ? "animate-spin" : ""} />
                        {isAligning ? "ALIGNING..." : "AUTO-ALIGN"}
                     </button>
                )}
                <span className="text-xs font-bold bg-white px-2 py-0.5 rounded border border-black">{subtitles.length}</span>
            </div>
        </div>
      <div className="overflow-y-auto flex-1 p-3 space-y-3 bg-gray-50">
        {subtitles.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center text-gray-400 opacity-80">
            <p className="font-bold text-lg">NO SUBTITLES</p>
            <p className="text-sm">Click 'AUTO GENERATE' to start!</p>
          </div>
        ) : (
          subtitles.map((sub, index) => {
            const isActive = currentTime >= sub.startTime && currentTime <= sub.endTime;
            
            return (
              <div
                key={sub.id}
                ref={isActive ? activeRef : null}
                className={`p-3 rounded-lg transition-all duration-200 border-2 ${
                  isActive
                    ? 'bg-yellow-200 border-black shadow-[4px_4px_0px_0px_rgba(0,0,0,1)] transform scale-[1.02]'
                    : 'bg-white border-gray-300 hover:border-black hover:shadow-[2px_2px_0px_0px_rgba(0,0,0,0.1)]'
                }`}
              >
                <div className="flex justify-between items-center mb-2">
                  <div className={`flex items-center space-x-2 text-xs font-mono font-bold px-2 py-1 rounded border border-black/10 ${isActive ? 'bg-yellow-300 text-black' : 'bg-gray-100 text-gray-600'}`}>
                    <Clock size={12} />
                    <span>{formatTime(sub.startTime).split(',')[0]}</span>
                    <span>→</span>
                    <span>{formatTime(sub.endTime).split(',')[0]}</span>
                  </div>
                  <span className="text-xs font-bold text-gray-400">#{index + 1}</span>
                </div>
                <div className="flex gap-2">
                  <textarea
                    value={sub.text}
                    onChange={(e) => onUpdateSubtitle(sub.id, e.target.value)}
                    className="flex-1 bg-transparent text-gray-900 font-medium text-sm focus:outline-none focus:underline rounded p-1 resize-none overflow-hidden"
                    rows={Math.max(1, Math.ceil(sub.text.length / 30))}
                    placeholder="Subtitle text..."
                  />
                  <button
                    onClick={() => onDeleteSubtitle(sub.id)}
                    className="text-gray-400 hover:text-red-500 transition-colors self-start p-1"
                    title="削除"
                  >
                    <Trash2 size={16} />
                  </button>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
};

export default SubtitleList;