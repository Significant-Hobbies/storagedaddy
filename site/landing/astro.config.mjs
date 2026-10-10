import { defineConfig } from 'astro/config';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';
import { finalizeLanding } from './scripts/finalize-landing.mjs';

export default defineConfig({
  output: 'static',
  site: 'https://storage.daddyrad.com',
  integrations: [react(), {
    name: 'storagedaddy-static-csp',
    hooks: { 'astro:build:done': ({ dir }) => finalizeLanding(dir) },
  }],
  build: { format: 'directory' },
  vite: { plugins: [tailwindcss()], build: { assetsInlineLimit: 0 } },
});
