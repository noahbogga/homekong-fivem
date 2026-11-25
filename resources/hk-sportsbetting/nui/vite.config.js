import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: '/mnt/fxmain/server-data/resources/[hk]/hk-sportsbetting/html',
    emptyOutDir: true,
    assetsDir: 'assets',
  },
  server: {
    port: 3000,
  },
})
