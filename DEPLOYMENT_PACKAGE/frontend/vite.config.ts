import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Backend (backend/server.js) listens on PORT (default 3000) and serves all
// routes under /api, so the proxy forwards /api unchanged.
const BACKEND_URL = 'http://localhost:3000'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: BACKEND_URL,
        changeOrigin: true,
      },
    },
  },
})
