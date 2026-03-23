# Use official Node.js LTS base image
FROM node:24-alpine

# Set working directory
WORKDIR /app

# Copy package files first for better caching
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy the rest of the app
COPY . .

# Expose the port the app runs on
EXPOSE 3200

# Start the application
CMD ["npm", "start"]