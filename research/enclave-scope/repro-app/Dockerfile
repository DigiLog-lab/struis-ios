FROM node:22-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202 AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
COPY src ./src
RUN --mount=type=secret,id=ca,target=/ca.crt NODE_EXTRA_CA_CERTS=/ca.crt npm ci --ignore-scripts --no-audit --no-fund --cache /tmp/npm \
 && npx tsc -p . && npm prune --omit=dev --ignore-scripts --no-audit --no-fund --cache /tmp/npm && rm -rf /tmp/npm /root/.npm
FROM node:22-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
USER node
CMD ["node","dist/server.js"]
