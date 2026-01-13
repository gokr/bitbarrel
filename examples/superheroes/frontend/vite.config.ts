import { defineConfig } from 'vite';
import solidPlugin from 'vite-plugin-solid';

export default defineConfig({
  plugins: [solidPlugin()],
  server: {
    port: 3000
  },
  resolve: {
    alias: {
      events: 'events',
      buffer: 'buffer'
    }
  },
  optimizeDeps: {
    include: ['events', 'buffer']
  },
  define: {
    'global': 'globalThis'
  }
});
