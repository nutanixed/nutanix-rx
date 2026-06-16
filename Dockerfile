FROM python:3.12-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    bash \
    openssh-client \
    sshpass \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY . .

# Expose the application port
EXPOSE 5005

# Environment variables will be passed via docker-compose or .env
ENV FLASK_APP=app.py

# Run the application with gunicorn and auto-reload enabled
CMD ["gunicorn", "--bind", "0.0.0.0:5005", "--workers", "1", "--timeout", "1200", "--reload", "app:app"]
