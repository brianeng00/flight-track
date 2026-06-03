import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],

  server: {
    proxy: {
      // Proxy OpenSky OAuth2 token endpoint — CORS not allowed from browsers
      '/opensky-token': {
        target: 'https://auth.opensky-network.org',
        changeOrigin: true,
        rewrite: () => '/auth/realms/opensky-network/protocol/openid-connect/token',
      },
      // Proxy OpenSky REST API — CORS not allowed from browsers
      '/opensky-api': {
        target: 'https://opensky-network.org',
        changeOrigin: true,
        rewrite: path => path.replace(/^\/opensky-api/, '/api'),
      },
    },
  },

  preview: {
    proxy: {
      '/opensky-token': {
        target: 'https://auth.opensky-network.org',
        changeOrigin: true,
        rewrite: () => '/auth/realms/opensky-network/protocol/openid-connect/token',
      },
      '/opensky-api': {
        target: 'https://opensky-network.org',
        changeOrigin: true,
        rewrite: path => path.replace(/^\/opensky-api/, '/api'),
      },
    },
  },
})
