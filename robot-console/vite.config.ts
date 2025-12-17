import path from "path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const stripGoogleFontsImport = {
  postcssPlugin: "strip-google-font-import",
  AtRule: {
    import(atRule: { params: string; remove: () => void }) {
      if (atRule.params.includes("googleapis")) {
        atRule.remove();
      }
    }
  }
};

export default defineConfig({
  plugins: [react()],
  css: {
    postcss: {
      plugins: [stripGoogleFontsImport]
    }
  },
  resolve: {
    alias: {
      "@polyflowrobotics/ui-components/style.css": path.resolve(
        __dirname,
        "node_modules/@polyflowrobotics/ui-components/style.css"
      )
    }
  },
  server: {
    port: 5173,
    strictPort: true
  }
});
