FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
WORKDIR /app/orchestrator-service
RUN npm run build
EXPOSE 3001
CMD ["node", "dist/main"]
