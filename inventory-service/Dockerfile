FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
WORKDIR /app/inventory-service
RUN npm run build
EXPOSE 3003
CMD ["node", "dist/inventory-service/src/main"]
