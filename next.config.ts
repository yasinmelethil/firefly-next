import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The legacy PHP API lives at http://<host>:8090/ffapi/firefly_api.php.
  // Serving the same path here means the ERP only ever changes host:port in
  // its stored API URL -- never the path, and never any client code.
  async rewrites() {
    return [
      {
        source: "/ffapi/firefly_api.php",
        destination: "/api/firefly",
      },
    ];
  },
};

export default nextConfig;
