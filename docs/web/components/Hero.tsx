import React from 'react';
import { ArrowRight, Download, Terminal } from 'lucide-react';
import { motion } from 'framer-motion';

const Hero: React.FC = () => {
  return (
    <section className="relative pt-32 lg:pt-48 pb-10 px-4 sm:px-6 lg:px-8 max-w-7xl mx-auto flex flex-col items-center text-center z-20">
      
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5 }}
        className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-red-50 border border-red-100 mb-8 backdrop-blur-sm"
      >
        <span className="flex h-2 w-2 rounded-full bg-red-500 animate-pulse"></span>
        <span className="text-xs font-medium text-red-600 tracking-wide uppercase">v0.1.0 Now Available</span>
      </motion.div>

      <motion.h1
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, delay: 0.1 }}
        className="text-5xl sm:text-7xl lg:text-8xl font-display font-bold tracking-tight mb-8 text-zinc-900"
      >
        <span className="block">
          Delete the
        </span>
        <span className="block text-transparent bg-clip-text bg-gradient-to-r from-primary to-orange-600">
          Unnecessary.
        </span>
      </motion.h1>

      <motion.p
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, delay: 0.2 }}
        className="text-xl text-zinc-500 max-w-2xl mb-10 leading-relaxed"
      >
        The most powerful open-source cleaning tool for developers. 
        Instantly reclaim space from <span className="text-zinc-900 font-bold">node_modules</span>, <span className="text-zinc-900 font-bold">Rust crates</span>, and build artifacts.
      </motion.p>

      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, delay: 0.3 }}
        className="flex flex-col sm:flex-row items-center gap-4 w-full sm:w-auto"
      >
        <a href="https://github.com/Augani/sweeper/releases" className="w-full sm:w-auto px-8 py-4 bg-primary text-white text-lg font-bold rounded-full hover:scale-105 transition-transform flex items-center justify-center gap-2 shadow-xl shadow-red-500/20 hover:bg-red-700">
          <Download className="w-5 h-5" />
          Download Free
        </a>
        <a href="https://github.com/Augani/sweeper" className="w-full sm:w-auto px-8 py-4 bg-white border border-zinc-200 text-zinc-900 text-lg font-bold rounded-full hover:bg-zinc-50 transition-colors flex items-center justify-center gap-2 shadow-sm">
          <Terminal className="w-5 h-5 text-zinc-500" />
          <span>View on GitHub</span>
        </a>
      </motion.div>

      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1, delay: 0.8 }}
        className="mt-12 text-sm text-zinc-500"
      >
        Built with Zig • Open Source (MIT) • macOS, Linux & Windows
      </motion.div>
    </section>
  );
};

export default Hero;