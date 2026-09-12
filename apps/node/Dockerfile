# Build context is the repo root (see docker-compose.yml).
FROM node:20-alpine
WORKDIR /app
COPY apps/node/package.json .
RUN npm install --omit=dev --no-audit --no-fund
COPY apps/node/src/ ./src/
EXPOSE 8080
CMD ["node", "src/server.js"]
