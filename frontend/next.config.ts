import type { NextConfig } from "next";

/**
 * FinAlly ships as a static export served by FastAPI on the same origin.
 * No server components runtime, no API routes, no middleware, no image loader.
 */
const nextConfig: NextConfig = {
  output: "export",
  // FastAPI serves the export with StaticFiles(html=True); emitting index.html
  // per route keeps directory-style URLs working without a rewrite layer.
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
  eslint: {
    // Lint is a separate `npm run lint` gate; don't fail the ship build on it.
    ignoreDuringBuilds: true,
  },
};

export default nextConfig;
