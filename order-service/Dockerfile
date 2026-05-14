FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
WORKDIR /app/order-service
RUN npm run build
EXPOSE 3002
CMD ["node", "dist/order-service/src/main"]
