# Cloud-Anrufbeantworter (Server) – ohne externe Abhängigkeiten
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
COPY public ./public
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 DATA_DIR=/data
VOLUME /data
EXPOSE 8080
USER node
CMD ["node", "src/server.js"]
