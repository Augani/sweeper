import React, { useState, useEffect } from 'react';
import Navbar from './components/Navbar';
import Hero from './components/Hero';
import Features from './components/Features';
import AppPreview from './components/AppPreview';
import Stats from './components/Stats';
import Footer from './components/Footer';
import { Download, Github, Terminal } from 'lucide-react';
import { motion, useScroll, useTransform } from 'framer-motion';

const App: React.FC = () => {
  const { scrollYProgress } = useScroll();
  const backgroundY = useTransform(scrollYProgress, [0, 1], ['0%', '20%']);

  return (
    <div className="min-h-screen bg-background overflow-hidden selection:bg-primary selection:text-white">
      {/* Background Ambient Effects - Adjusted for Light Mode */}
      <div className="fixed inset-0 z-0 pointer-events-none opacity-40">
        <div className="absolute top-[-10%] left-[-10%] w-[500px] h-[500px] bg-red-200 rounded-full blur-[128px] animate-blob mix-blend-multiply" />
        <div className="absolute top-[20%] right-[-10%] w-[400px] h-[400px] bg-orange-200 rounded-full blur-[128px] animate-blob animation-delay-2000 mix-blend-multiply" />
        <div className="absolute bottom-[-10%] left-[20%] w-[600px] h-[600px] bg-rose-200 rounded-full blur-[128px] animate-blob animation-delay-4000 mix-blend-multiply" />
      </div>

      <div className="relative z-10">
        <Navbar />
        
        <main className="flex flex-col gap-24 pb-24">
          <Hero />
          
          <section id="preview" className="container mx-auto px-4 sm:px-6 lg:px-8">
            <AppPreview />
          </section>

          <Features />
          
          <Stats />

          <section className="container mx-auto px-4 py-20 relative">
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-12 text-center shadow-2xl max-w-4xl mx-auto overflow-hidden relative">
              {/* Subtle accent in the dark card */}
              <div className="absolute top-0 right-0 w-64 h-64 bg-primary/20 blur-[80px] rounded-full pointer-events-none"></div>

              <h2 className="text-4xl md:text-5xl font-display font-bold mb-6 text-white relative z-10">
                Ready to reclaim your space?
              </h2>
              <p className="text-xl text-gray-400 mb-8 max-w-2xl mx-auto relative z-10">
                Join developers who have cleared terabytes of unused data. Open source, fast, and safe.
              </p>
              <div className="flex flex-col sm:flex-row gap-4 justify-center items-center relative z-10">
                <a href="https://github.com/Augani/sweeper/releases" className="px-8 py-4 bg-primary text-white font-bold rounded-full hover:bg-red-700 transition-colors flex items-center gap-2 group shadow-lg shadow-red-900/20">
                  <Download className="w-5 h-5 group-hover:translate-y-1 transition-transform" />
                  Download GUI
                </a>
                <a href="https://github.com/Augani/sweeper/releases" className="px-8 py-4 bg-white/10 border border-white/20 text-white font-bold rounded-full hover:bg-white/20 transition-colors flex items-center gap-2">
                  <Terminal className="w-5 h-5" />
                  Download CLI
                </a>
                <a href="https://github.com/Augani/sweeper" target="_blank" rel="noopener noreferrer" className="px-8 py-4 bg-white/10 border border-white/20 text-white font-bold rounded-full hover:bg-white/20 transition-colors flex items-center gap-2">
                  <Github className="w-5 h-5" />
                  Source
                </a>
              </div>
              <p className="mt-6 text-sm text-gray-500 relative z-10">
                Available for macOS, Linux, and Windows • GUI (~1MB) • CLI (~633KB)
              </p>
            </div>
          </section>
        </main>

        <Footer />
      </div>
    </div>
  );
};

export default App;