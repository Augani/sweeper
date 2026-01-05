import React, { useState, useEffect } from 'react';
import { Eraser, Menu, X, Github } from 'lucide-react';

const Navbar: React.FC = () => {
  const [isScrolled, setIsScrolled] = useState(false);
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false);

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(window.scrollY > 20);
    };
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);

  return (
    <nav className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${isScrolled ? 'bg-white/80 backdrop-blur-md border-b border-zinc-200 py-4' : 'bg-transparent py-6'}`}>
      <div className="container mx-auto px-4 sm:px-6 lg:px-8 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-10 h-10 bg-gradient-to-tr from-primary to-secondary rounded-xl flex items-center justify-center shadow-lg shadow-red-200">
            <Eraser className="w-6 h-6 text-white" />
          </div>
          <span className="text-xl font-display font-bold tracking-tight text-zinc-900">Sweeper</span>
        </div>

        <div className="hidden md:flex items-center gap-8">
          <a href="#features" className="text-sm font-medium text-zinc-600 hover:text-primary transition-colors">Features</a>
          <a href="#how-it-works" className="text-sm font-medium text-zinc-600 hover:text-primary transition-colors">How it works</a>
          <a href="#stats" className="text-sm font-medium text-zinc-600 hover:text-primary transition-colors">Impact</a>
          <div className="w-px h-4 bg-zinc-200"></div>
          <a href="https://github.com" target="_blank" rel="noopener noreferrer" className="text-zinc-600 hover:text-primary transition-colors">
            <Github className="w-5 h-5" />
          </a>
          <button className="px-5 py-2 bg-zinc-900 text-white text-sm font-bold rounded-full hover:bg-zinc-800 transition-colors">
            Download
          </button>
        </div>

        <button 
          className="md:hidden text-zinc-900"
          onClick={() => setIsMobileMenuOpen(!isMobileMenuOpen)}
        >
          {isMobileMenuOpen ? <X /> : <Menu />}
        </button>
      </div>

      {/* Mobile Menu */}
      {isMobileMenuOpen && (
        <div className="md:hidden absolute top-full left-0 right-0 bg-white border-b border-zinc-200 p-4 flex flex-col gap-4 shadow-xl">
          <a href="#features" className="text-sm font-medium text-zinc-600 hover:text-primary" onClick={() => setIsMobileMenuOpen(false)}>Features</a>
          <a href="#how-it-works" className="text-sm font-medium text-zinc-600 hover:text-primary" onClick={() => setIsMobileMenuOpen(false)}>How it works</a>
          <a href="#stats" className="text-sm font-medium text-zinc-600 hover:text-primary" onClick={() => setIsMobileMenuOpen(false)}>Impact</a>
          <button className="w-full py-3 bg-primary text-white text-sm font-bold rounded-lg">
            Download
          </button>
        </div>
      )}
    </nav>
  );
};

export default Navbar;