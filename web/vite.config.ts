import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
export default defineConfig({
  root,
  plugins: [react()],
  cacheDir: `${root}/.vite`,
  build: { outDir: `${root}/dist`, emptyOutDir: true },
  server: { proxy: { "/v1": { target: `http://127.0.0.1:${process.env.RA_PORT || 47823}`, changeOrigin: true } } },
});
