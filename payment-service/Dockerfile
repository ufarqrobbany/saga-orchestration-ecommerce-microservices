FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
WORKDIR /app/payment-service
RUN npm run build
EXPOSE 3004
CMD ["node", "dist/main"]
