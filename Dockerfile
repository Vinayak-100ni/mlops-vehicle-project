# syntax=docker/dockerfile:1.7
#
# Single-container build for the PV Case Intake Automation prototype.
#
# What runs inside the image:
#   * nginx          — serves the built workbench (static) and reverse-proxies
#                       /api/* to the api-server on 127.0.0.1:8080
#   * node           — the bundled api-server (esbuild output, listens on 8080)
#
# What is NOT in the image (must be supplied at runtime):
#   * PostgreSQL — pass DATABASE_URL pointing at an external Postgres
#                  (Aurora, RDS, a managed Postgres, etc.)
#   * Any other secrets the app reads from env (see replit.md / docs/AWS_DEPLOYMENT.md)
#
# Build:   docker build -t pv-intake .
# Run:     docker run --rm -p 8080:8080 \
#            -e DATABASE_URL='postgres://user:pass@host:5432/db' \
#            -e SESSION_SECRET='...' \
#            -e INBOUND_WEBHOOK_SECRET='...' \
#            pv-intake
#
# The container exposes a single HTTP port (default 8080) that serves both the
# UI and /api. Override with -e PORT=… and -p <hostPort>:<PORT>.
#
# AWS path-prefix routing (one ALB serving the workbench at `/` and routing
# `/<prefix>/*` to the api-server target group):
#   docker build \
#     --build-arg VITE_API_BASE_URL=/backend \
#     -t pv-intake .
#   # then on the api-server container:
#   #   -e BACKEND_PATH_PREFIX=/backend
# `VITE_API_BASE_URL` MUST be passed at BUILD time (Vite inlines it into the
# bundle); setting it on the running container has no effect. Leave both
# unset for same-origin (Replit dev or single-container) deployments.

############################
# 1. Base toolchain (pnpm) #
############################
FROM node:20-bookworm-slim AS base
ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"
ENV CI=1
RUN corepack enable && corepack prepare pnpm@10.26.1 --activate
WORKDIR /repo


############################
# 2. Install full deps     #
############################
FROM base AS deps
# Copy only the metadata first so the install layer is cacheable.
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY artifacts/api-server/package.json   artifacts/api-server/package.json
COPY artifacts/workbench/package.json    artifacts/workbench/package.json
COPY artifacts/mockup-sandbox/package.json artifacts/mockup-sandbox/package.json
COPY lib/api-spec/package.json           lib/api-spec/package.json
COPY lib/api-client-react/package.json   lib/api-client-react/package.json
COPY lib/db/package.json                 lib/db/package.json
COPY lib/replit-auth-web/package.json    lib/replit-auth-web/package.json
# If you add more workspace packages, mirror their package.json copies here.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile


############################
# 3. Build everything      #
############################
FROM deps AS build
COPY . .
# Regenerate the OpenAPI client from the spec (orval + zod) and typecheck libs.
RUN pnpm --filter @workspace/api-spec run codegen
# Build the workbench. BASE_PATH=/ so the static bundle is mounted at the
# container root by nginx (no /workbench prefix in production).
# VITE_API_BASE_URL is baked into the bundle at build time (Vite inlines
# `import.meta.env.VITE_*`). Default empty = same-origin `/api/...` calls.
# Set to e.g. `/backend` for AWS path-prefix routing on a shared ALB.
ARG VITE_API_BASE_URL=""
RUN BASE_PATH=/ NODE_ENV=production VITE_API_BASE_URL="${VITE_API_BASE_URL}" \
    pnpm --filter @workspace/workbench run build
# Build the api-server (esbuild → dist/index.mjs + worker bundles).
RUN pnpm --filter @workspace/api-server run build


########################################
# 4. Produce a flat prod node_modules  #
#    for the api-server only           #
########################################
FROM deps AS prod-deps
COPY . .
# `pnpm deploy` copies a self-contained, hoisted node_modules tree for the
# selected workspace package — exactly what we want at runtime.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm deploy --filter @workspace/api-server --prod /out


############################
# 5. Final runtime image   #
############################
FROM node:20-bookworm-slim AS runtime
ENV NODE_ENV=production
ENV PORT=8080
# Internal port the bundled api-server listens on (kept off the public port).
ENV API_INTERNAL_PORT=8081

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx tini ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

WORKDIR /app

# api-server runtime: bundled output + the flat prod node_modules tree.
COPY --from=build     /repo/artifacts/api-server/dist        ./api-server/dist
COPY --from=prod-deps /out/node_modules                      ./api-server/node_modules
COPY --from=prod-deps /out/package.json                      ./api-server/package.json

# Built workbench static assets — served directly by nginx.
COPY --from=build /repo/artifacts/workbench/dist             ./workbench

# nginx config + container entrypoint.
COPY docker/nginx.conf      /etc/nginx/nginx.conf
COPY docker/entrypoint.sh   /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

# tini reaps zombies and forwards signals to nginx + node cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
