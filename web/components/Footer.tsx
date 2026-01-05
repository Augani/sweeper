import React from 'react';
import { Github, Heart } from 'lucide-react';

const Footer: React.FC = () => {
  return (
    <footer className="border-t border-zinc-800 bg-zinc-950 pt-16 pb-8">
      <div className="container mx-auto px-4 sm:px-6 lg:px-8">
        <div className="grid grid-cols-1 md:grid-cols-4 gap-12 mb-12">
          <div className="col-span-1 md:col-span-2">
            <div className="flex items-center gap-2 mb-4">
              <span className="text-2xl font-display font-bold text-white">Sweeper</span>
            </div>
            <p className="text-zinc-400 max-w-sm">
              The ultimate disk cleaning utility for developers. Open source, fast, and privacy-focused.
              Made with <Heart className="w-3 h-3 inline text-red-500 fill-red-500" /> by developers, for developers.
            </p>
          </div>
          
          <div>
            <h4 className="text-white font-bold mb-4">Product</h4>
            <ul className="space-y-2">
              <li><a href="https://github.com/Augani/sweeper/releases" className="text-zinc-400 hover:text-white transition-colors">Download</a></li>
              <li><a href="https://github.com/Augani/sweeper/releases" className="text-zinc-400 hover:text-white transition-colors">Changelog</a></li>
              <li><a href="https://github.com/Augani/sweeper#readme" className="text-zinc-400 hover:text-white transition-colors">Documentation</a></li>
              <li><a href="https://github.com/Augani/sweeper" className="text-zinc-400 hover:text-white transition-colors">Source Code</a></li>
            </ul>
          </div>

          <div>
            <h4 className="text-white font-bold mb-4">Legal</h4>
            <ul className="space-y-2">
              <li><a href="https://github.com/Augani/sweeper/blob/main/LICENSE" className="text-zinc-400 hover:text-white transition-colors">MIT License</a></li>
              <li><a href="https://github.com/Augani/sweeper/blob/main/CONTRIBUTING.md" className="text-zinc-400 hover:text-white transition-colors">Contributing</a></li>
            </ul>
          </div>
        </div>
        
        <div className="flex flex-col md:flex-row justify-between items-center border-t border-zinc-800 pt-8">
          <div className="text-zinc-500 text-sm mb-4 md:mb-0">
            © {new Date().getFullYear()} Sweeper Inc. All rights reserved.
          </div>
          <div className="flex gap-6">
            <a href="https://github.com/Augani/sweeper" target="_blank" rel="noopener noreferrer" className="text-zinc-400 hover:text-white transition-colors"><Github className="w-5 h-5" /></a>
          </div>
        </div>
      </div>
    </footer>
  );
};

export default Footer;