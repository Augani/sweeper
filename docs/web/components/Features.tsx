import React from 'react';
import { Layers, Zap, Clock, Code, Database, ShieldCheck, RefreshCw, Trash2 } from 'lucide-react';

const FEATURES = [
  {
    icon: Layers,
    title: 'Deep Scan Technology',
    description: 'Intelligently identifies nested node_modules, target directories, and hidden build caches that regular cleaners miss.'
  },
  {
    icon: Clock,
    title: 'Stale File Detection',
    description: 'Automatically flags projects and files you haven\'t touched in over 90 days, keeping your active workspace clean.'
  },
  {
    icon: Code,
    title: 'Developer Centric',
    description: 'Built specifically for developers. We know what `cargo clean` and `npm prune` do, but we do it across your entire drive at once.'
  },
  {
    icon: Database,
    title: 'Cache Buster',
    description: 'Wipes specific cache directories for package managers like Yarn, npm, pnpm, and Cargo without breaking your projects.'
  },
  {
    icon: Zap,
    title: 'Blazing Fast',
    description: 'Written in Zig with raylib for maximum performance. Tiny binaries (~1MB GUI, ~630KB TUI) that scan your storage in seconds.'
  },
  {
    icon: ShieldCheck,
    title: 'Safe Delete',
    description: 'Items are moved to your system Trash first. Review everything before permanent deletion. Empty your Trash to see the freed space.'
  },
  {
    icon: RefreshCw,
    title: 'Run Multiple Times',
    description: 'Keep running Sweeper to discover new build artifacts as you work. Each scan finds freshly created node_modules and caches.'
  },
  {
    icon: Trash2,
    title: 'Empty Trash to Free Space',
    description: 'Files are moved to Trash for safety. To actually reclaim disk space, empty your system Trash after cleaning with Sweeper.'
  }
];

const Features: React.FC = () => {
  return (
    <section id="features" className="container mx-auto px-4 sm:px-6 lg:px-8 py-20">
      <div className="text-center max-w-3xl mx-auto mb-16">
        <h2 className="text-3xl md:text-5xl font-display font-bold text-zinc-900 mb-6">
          More than just a file deleter.
        </h2>
        <p className="text-zinc-500 text-lg">
          Sweeper understands your development environment. It knows the difference between a critical config file and a 2GB build artifact.
        </p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
        {FEATURES.map((feature, idx) => {
          const Icon = feature.icon;
          return (
            <div key={idx} className="group p-8 rounded-2xl bg-white border border-zinc-200 hover:border-red-500/50 hover:shadow-xl hover:shadow-red-500/5 transition-all duration-300 relative overflow-hidden">
              <div className="absolute top-0 right-0 p-4 opacity-0 group-hover:opacity-10 transition-opacity">
                <Icon className="w-24 h-24 text-red-500" />
              </div>
              <div className="w-12 h-12 bg-red-50 rounded-lg flex items-center justify-center mb-6 group-hover:scale-110 transition-transform duration-300">
                <Icon className="w-6 h-6 text-red-600" />
              </div>
              <h3 className="text-xl font-bold text-zinc-900 mb-3 font-display">{feature.title}</h3>
              <p className="text-zinc-500 leading-relaxed">
                {feature.description}
              </p>
            </div>
          );
        })}
      </div>
    </section>
  );
};

export default Features;