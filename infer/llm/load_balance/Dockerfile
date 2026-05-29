FROM python:3.11-slim

WORKDIR /app

# Install Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy load balancer source
COPY lb_server.py .

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "lb_server.py"]
