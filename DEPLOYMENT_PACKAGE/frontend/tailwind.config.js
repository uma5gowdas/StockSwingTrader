/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        'chart-blue': '#3b82f6',
        'chart-green': '#10b981',
        'chart-red': '#ef4444',
        'dark-bg': '#0f172a',
        'dark-card': '#1e293b',
      }
    },
  },
  plugins: [],
}
