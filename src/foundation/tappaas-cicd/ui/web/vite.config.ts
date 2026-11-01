// The console's front end. `npm run dev` proxies /api to a console backend on
// loopback (CONSOLE_DEV_API, default the dev port 9197).
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

// var() is not valid in a media query, so a query's --bp-* is swapped for that
// token's value on :root before the CSS is parsed. An unknown token stops the build.
function breakpoints(): Plugin {
  return {
    name: "console-breakpoints",
    enforce: "pre",
    transform(code, id) {
      if (!id.split("?")[0].endsWith(".css")) return null;
      return code.replace(/@media[^{]*/g, (query) =>
        query.replace(/var\((--bp-[a-z]+)\)/g, (_, token: string) => {
          const value = new RegExp(`${token}:\\s*(\\d+px)`).exec(code)?.[1];
          if (!value) throw new Error(`${id}: no ${token} on :root`);
          return value;
        }),
      );
    },
  };
}

export default defineConfig({
  plugins: [react(), breakpoints()],
  base: "/",
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 900 },
  server: { proxy: { "/api": process.env.CONSOLE_DEV_API ?? "http://127.0.0.1:9197" } },
});
