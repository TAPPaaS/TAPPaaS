// The console's front end. `npm run dev` proxies /api to a console backend on
// loopback (CONSOLE_DEV_API, default the dev port 9197).
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/",
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 900 },
  server: { proxy: { "/api": process.env.CONSOLE_DEV_API ?? "http://127.0.0.1:9197" } },
});
