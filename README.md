# Gemini Agent App

A Python FastAPI application that uses Google Gemini with function-calling and popular tools:
- Web search (DuckDuckGo Instant Answer)
- Fetch URL and extract readable text
- Safe calculator

## Features

- **Automatic Vertex AI detection**: When running in GCP, automatically uses Vertex AI (no API key needed)
- **Public API fallback**: If not in GCP, uses public Gemini API (requires API key)
- **Tool calling**: Web search, URL fetching, and calculator tools
- **Web UI**: Simple web interface for testing

## Quick Start

### Deploy to GCP VM

```bash
./auto-deploy-gcp.sh [project-id] [vm-name] [zone]
```

Example:
```bash
./auto-deploy-gcp.sh airs20-poc
```

This will:
1. Create a Debian VM in GCP
2. Set up firewall rules
3. Deploy and configure the application
4. Start the service on port 80

### Monitor API Requests

```bash
./watch-api-requests.sh
```

## Configuration

Copy `env.sample` to `.env` and configure:

```bash
cp env.sample .env
```

For GCP deployments, the project ID is auto-detected. For local development, set `GEMINI_API_KEY`.

## Project Structure

```
.
├── app/                    # FastAPI application
│   ├── main.py            # Main FastAPI app
│   ├── routes/            # API routes
│   ├── services/          # Agent and tools
│   └── templates/         # Web UI
├── auto-deploy-gcp.sh     # Automated GCP deployment
├── watch-api-requests.sh   # Monitor API requests
├── requirements.txt       # Python dependencies
└── env.sample            # Environment template
```

## API Usage

```bash
curl -X POST http://your-vm-ip/api/chat \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2+2?"}'
```

## Requirements

- Python 3.10+
- For GCP: gcloud CLI configured
- For local: Gemini API key from https://makersuite.google.com/app/apikey

