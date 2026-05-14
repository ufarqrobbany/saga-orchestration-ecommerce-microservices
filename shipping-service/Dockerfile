FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
WORKDIR /app/shipping-service
RUN npm run build
EXPOSE 3005
CMD ["node", "dist/shipping-service/src/main"]
