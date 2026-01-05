import React from 'react';

const Stats: React.FC = () => {
  return (
    <section id="stats" className="border-y border-zinc-200 bg-zinc-50">
      <div className="container mx-auto px-4 sm:px-6 lg:px-8 py-16">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-8">
          <div className="text-center">
            <div className="text-4xl md:text-5xl font-bold text-zinc-900 mb-2 font-display">~1 MB</div>
            <div className="text-sm text-zinc-500 uppercase tracking-wider font-medium">GUI Binary Size</div>
          </div>
          <div className="text-center">
            <div className="text-4xl md:text-5xl font-bold text-zinc-900 mb-2 font-display">~630 KB</div>
            <div className="text-sm text-zinc-500 uppercase tracking-wider font-medium">TUI Binary Size</div>
          </div>
          <div className="text-center">
            <div className="text-4xl md:text-5xl font-bold text-zinc-900 mb-2 font-display">100%</div>
            <div className="text-sm text-zinc-500 uppercase tracking-wider font-medium">Open Source</div>
          </div>
          <div className="text-center">
            <div className="text-4xl md:text-5xl font-bold text-zinc-900 mb-2 font-display">15+</div>
            <div className="text-sm text-zinc-500 uppercase tracking-wider font-medium">Supported Languages</div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default Stats;