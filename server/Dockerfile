FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json ./
COPY src ./src
RUN mkdir -p /app/data && chown -R node:node /app
USER node
ENV DATABASE_PATH=/app/data/wochenleicht.sqlite PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["node", "--disable-warning=ExperimentalWarning", "src/index.js"]
