import React, { useState } from 'react';
import { PieChart, Pie, Cell, ResponsiveContainer } from 'recharts';
import { FolderOpen, Trash2, HardDrive, Code2, Layers, Archive, RefreshCw, CheckCircle2 } from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';

const CATEGORIES = [
  { id: 'all', label: 'All', icon: HardDrive },
  { id: 'largest', label: 'Largest', icon: FolderOpen },
  { id: 'cache', label: 'Cache', icon: Layers },
  { id: 'dev', label: 'Dev Artifacts', icon: Code2 },
  { id: 'temp', label: 'Temp', icon: Archive },
];

// Updated colors to match the Red theme
const MOCK_DATA = [
  { name: 'Node Modules', value: 45, color: '#dc2626' }, // primary red
  { name: 'Rust Builds', value: 25, color: '#f87171' }, // lighter red
  { name: 'Docker Overlay', value: 20, color: '#b91c1c' }, // dark red
  { name: 'Temp Files', value: 10, color: '#52525b' }, // gray
];

const MOCK_FILES = [
  { id: 1, name: 'project-alpha/node_modules', size: '842 MB', type: 'Node', lastUsed: '4 months ago', category: 'dev' },
  { id: 2, name: 'backend-v1/target', size: '2.1 GB', type: 'Rust', lastUsed: '95 days ago', category: 'dev' },
  { id: 3, name: 'vscode-cpp-tools', size: '450 MB', type: 'Cache', lastUsed: '6 months ago', category: 'cache' },
  { id: 4, name: 'old-logs-2023.tar.gz', size: '1.2 GB', type: 'Archive', lastUsed: '1 year ago', category: 'largest' },
  { id: 5, name: 'legacy-project/vendor', size: '600 MB', type: 'PHP', lastUsed: '2 years ago', category: 'dev' },
  { id: 6, name: 'yarn-cache-v6', size: '3.4 GB', type: 'Cache', lastUsed: '1 week ago', category: 'cache' },
  { id: 7, name: 'tmp-download-x84', size: '800 MB', type: 'Temp', lastUsed: '2 days ago', category: 'temp' },
];

const AppPreview: React.FC = () => {
  const [activeCategory, setActiveCategory] = useState('all');
  const [isScanning, setIsScanning] = useState(false);
  const [cleaned, setCleaned] = useState<number[]>([]);

  const filteredFiles = activeCategory === 'all' 
    ? MOCK_FILES 
    : MOCK_FILES.filter(f => f.category === 'dev' && activeCategory === 'dev' || f.category === activeCategory || (activeCategory === 'largest' && parseFloat(f.size) > 1));

  const handleClean = (id: number) => {
    setCleaned([...cleaned, id]);
  };

  const handleScan = () => {
    setIsScanning(true);
    setCleaned([]);
    setTimeout(() => setIsScanning(false), 2000);
  };

  return (
    <div className="relative mx-auto max-w-5xl">
      {/* Decorative glass glow behind mock - Red tinted */}
      <div className="absolute -inset-1 bg-gradient-to-r from-red-500 to-orange-500 rounded-2xl blur opacity-20"></div>
      
      {/* App Window - Keeping it Dark Mode for sleek contrast against white page */}
      <div className="relative bg-[#0f0f11] rounded-xl border border-zinc-800 shadow-2xl overflow-hidden flex flex-col md:flex-row h-[600px]">
        
        {/* Sidebar */}
        <div className="w-full md:w-64 bg-[#18181b] border-r border-white/5 p-4 flex flex-col">
          <div className="flex items-center gap-2 px-2 mb-8">
            <div className="flex gap-1.5">
              <div className="w-3 h-3 rounded-full bg-red-500/80"></div>
              <div className="w-3 h-3 rounded-full bg-yellow-500/80"></div>
              <div className="w-3 h-3 rounded-full bg-green-500/80"></div>
            </div>
          </div>

          <div className="space-y-1">
            {CATEGORIES.map(cat => {
              const Icon = cat.icon;
              return (
                <button
                  key={cat.id}
                  onClick={() => setActiveCategory(cat.id)}
                  className={`w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                    activeCategory === cat.id 
                      ? 'bg-red-500/10 text-red-500' 
                      : 'text-gray-400 hover:text-white hover:bg-white/5'
                  }`}
                >
                  <Icon className="w-4 h-4" />
                  {cat.label}
                </button>
              );
            })}
          </div>

          <div className="mt-auto pt-6 border-t border-white/5">
            <div className="p-3 bg-white/5 rounded-lg">
              <div className="text-xs text-gray-400 mb-2">Storage Saved</div>
              <div className="text-2xl font-bold text-white mb-1">347 GB</div>
              <div className="w-full h-1.5 bg-white/10 rounded-full overflow-hidden">
                <div className="h-full bg-red-500 w-[75%]"></div>
              </div>
            </div>
          </div>
        </div>

        {/* Main Content */}
        <div className="flex-1 flex flex-col bg-[#0f0f11]">
          {/* Header */}
          <div className="h-16 border-b border-white/5 flex items-center justify-between px-6">
            <h2 className="text-lg font-medium text-white">System Scan</h2>
            <button 
              onClick={handleScan}
              disabled={isScanning}
              className={`px-4 py-2 rounded-lg text-sm font-bold flex items-center gap-2 transition-all ${
                isScanning ? 'bg-white/5 text-gray-400' : 'bg-primary text-white hover:bg-red-700'
              }`}
            >
              <RefreshCw className={`w-4 h-4 ${isScanning ? 'animate-spin' : ''}`} />
              {isScanning ? 'Scanning...' : 'Rescan'}
            </button>
          </div>

          {/* Visualization Area */}
          <div className="flex-1 overflow-hidden flex flex-col">
            <div className="p-6 grid grid-cols-1 lg:grid-cols-3 gap-6 h-full">
              
              {/* Chart Section */}
              <div className="lg:col-span-1 bg-[#18181b] rounded-xl p-4 border border-white/5 flex flex-col">
                <h3 className="text-sm font-medium text-gray-400 mb-4">Space Breakdown</h3>
                <div className="flex-1 min-h-[200px]">
                  <ResponsiveContainer width="100%" height="100%">
                    <PieChart>
                      <Pie
                        data={MOCK_DATA}
                        innerRadius={60}
                        outerRadius={80}
                        paddingAngle={5}
                        dataKey="value"
                      >
                        {MOCK_DATA.map((entry, index) => (
                          <Cell key={`cell-${index}`} fill={entry.color} stroke="none" />
                        ))}
                      </Pie>
                    </PieChart>
                  </ResponsiveContainer>
                </div>
                <div className="space-y-2 mt-4">
                  {MOCK_DATA.map((item, i) => (
                    <div key={i} className="flex items-center justify-between text-xs">
                      <div className="flex items-center gap-2">
                        <div className="w-2 h-2 rounded-full" style={{ backgroundColor: item.color }}></div>
                        <span className="text-gray-400">{item.name}</span>
                      </div>
                      <span className="text-white font-medium">{item.value}%</span>
                    </div>
                  ))}
                </div>
              </div>

              {/* List Section */}
              <div className="lg:col-span-2 bg-[#18181b] rounded-xl border border-white/5 flex flex-col overflow-hidden">
                <div className="p-4 border-b border-white/5 flex justify-between items-center bg-white/[0.02]">
                  <span className="text-xs font-medium text-gray-500 uppercase tracking-wider">File Path</span>
                  <span className="text-xs font-medium text-gray-500 uppercase tracking-wider">Size</span>
                </div>
                
                <div className="flex-1 overflow-y-auto custom-scrollbar p-2 space-y-1">
                  <AnimatePresence>
                    {filteredFiles.map((file) => (
                      !cleaned.includes(file.id) ? (
                        <motion.div
                          key={file.id}
                          initial={{ opacity: 0, x: -10 }}
                          animate={{ opacity: 1, x: 0 }}
                          exit={{ opacity: 0, height: 0, marginTop: 0, marginBottom: 0, overflow: 'hidden' }}
                          className="group flex items-center justify-between p-3 rounded-lg hover:bg-white/5 transition-colors"
                        >
                          <div className="flex items-center gap-3 overflow-hidden">
                            <div className="w-8 h-8 rounded-lg bg-white/5 flex items-center justify-center flex-shrink-0">
                              <Code2 className="w-4 h-4 text-gray-400" />
                            </div>
                            <div className="flex flex-col overflow-hidden">
                              <span className="text-sm text-gray-200 truncate font-mono">{file.name}</span>
                              <span className="text-xs text-gray-500">Unused for {file.lastUsed}</span>
                            </div>
                          </div>
                          <div className="flex items-center gap-4 flex-shrink-0">
                            <span className="text-sm font-medium text-white">{file.size}</span>
                            <button 
                              onClick={() => handleClean(file.id)}
                              className="w-8 h-8 rounded-full bg-white/5 hover:bg-red-500/20 hover:text-red-400 text-gray-400 flex items-center justify-center transition-colors"
                              title="Clean"
                            >
                              <Trash2 className="w-4 h-4" />
                            </button>
                          </div>
                        </motion.div>
                      ) : null
                    ))}
                    {filteredFiles.length === 0 && (
                      <div className="h-full flex flex-col items-center justify-center text-gray-500">
                        <CheckCircle2 className="w-8 h-8 mb-2 opacity-50" />
                        <span className="text-sm">No files found in this category</span>
                      </div>
                    )}
                  </AnimatePresence>
                </div>
              </div>
            </div>
          </div>

        </div>
      </div>
    </div>
  );
};

export default AppPreview;