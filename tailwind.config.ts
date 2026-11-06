import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        background: "#090B0C",
        card: "#141719",
        surface: "#1B2021",
        foreground: "#F1F3F2",
        muted: "#929A9A",
        border: "#23292B",
        accent: { DEFAULT: "#0D9488", light: "#2DD4BF" },
      },
    },
  },
  plugins: [],
};

export default config;
