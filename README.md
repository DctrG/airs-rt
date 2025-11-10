# AI Agent App

A Python FastAPI application implementing an AI agent that uses Google Gemini with function-calling and popular tools:
- Web search (DuckDuckGo Instant Answer)
- Fetch URL and extract readable text
- Safe calculator

## Features

- **Automated deployment**: One-command deployment to GCP Compute Engine with automatic setup
- **Automatic Vertex AI detection**: Uses Vertex AI with Application Default Credentials (no API key needed when running in GCP)
- **Tool calling**: Web search, URL fetching, and calculator tools
- **Real-time logging**: Monitor API requests and responses in real-time with detailed headers and status codes


## Configuration

The application automatically detects the GCP project when deployed to a VM. No manual configuration needed - the deployment script handles everything:

- Auto-detection of `GOOGLE_CLOUD_PROJECT` from the metadata server
- Vertex AI initialization with Application Default Credentials
- Firewall rules configuration with auto-detected Cloud Shell IP and Prisma AIRS RT IP
- Required API enablement
- Service account permission setup

## Deployment

### Prerequisites

- GCP project with billing enabled

### Deploy to GCP VM

Run the deployment script from Cloud Shell:

```bash
./deploy.sh
```

**Optional Arguments:**
- `project-id`: GCP project ID (required)
- `vm-name`: VM name (default: `gemini-agent-vm`)
- `zone`: GCP zone (default: `us-central1-a`)

**Examples:**

Basic deployment:
```bash
./deploy.sh
```

With custom project, VM name and zone:
```bash
./deploy.sh airs20-poc my-gemini-vm us-central1-b
```

### What the Script Does

The deployment script performs the following steps automatically:

1. **GitHub Update Check**: Checks for newer code in GitHub and pulls if available
2. **IP Detection**: Auto-detects Cloud Shell's external IP address
3. **API Enablement**: Checks and enables required APIs (Compute Engine, Vertex AI)
4. **Service Account Setup**: Verifies and grants `roles/aiplatform.user` permission
5. **Network Setup**: Creates default VPC network if it doesn't exist
6. **Firewall Configuration**: Creates/updates firewall rules (allows Cloud Shell IP + GCP health checker)
7. **VM Creation**: Creates Debian 12 VM if it doesn't exist (e2-small, 15GB disk)
8. **Application Deployment**: Packages and deploys application code
9. **Service Configuration**: Sets up systemd service running on port 80
10. **Testing**: Tests health and API endpoints with curl
11. **Output**: Provides access URLs and useful commands

## Usage


### API Endpoint

Send requests to the `/api/chat` endpoint:

```bash
curl -X POST http://your-vm-ip/api/chat \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2+2?"}'
```

**Request format:**
```json
{
  "prompt": "Your question or instruction here"
}
```

**Response format:**
```json
{
  "text": "The agent's response text"
}
```

### Health Check

Check if the service is running:

```bash
curl http://your-vm-ip/health
```

**Response:**
```json
{
  "status": "ok"
}
```

### AIRS RT Setup

**cURL String:**
```bash
curl \
  "http://your-vm-ip/api/chat" \
  -H "Content-Type: application/json" \
  --data '{"prompt":"What is 2+2?"}'
```

**Request JSON:**
```json
{
  "prompt": "{INPUT}"
}
```

**Response JSON:**
```json
{
  "text": "{RESPONSE}"
}
```

### Monitor API Requests

Watch API requests and responses in real-time:

```bash
./watch-api-requests.sh [vm-name] [zone] [project-id]
```

This will show:
- API requests with client IP and headers
- API responses with status codes
- Tool calls and results

## Project Structure

```
.
├── app/                    # FastAPI application
│   ├── main.py            # Main FastAPI app
│   ├── routes/            # API routes
│   │   └── api.py         # Chat endpoint
│   ├── services/          # Agent and tools
│   │   ├── agent.py       # Gemini agent orchestration
│   │   └── tools/         # Tool implementations
│   │       ├── registry.py
│   │       ├── webSearch.py
│   │       ├── fetchUrl.py
│   │       └── calculator.py
│   └── templates/         # Web UI
│       └── index.html
├── deploy.sh              # Automated GCP deployment script
├── watch-api-requests.sh  # Monitor API requests
├── requirements.txt       # Python dependencies
└── README.md             # This file
```


### Delete VM

To completely remove the instance:

```bash
gcloud compute instances delete gemini-agent-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
```

## Useful Commands

After deployment, the script outputs useful commands including:
- SSH access
- Log viewing
- Service restart
- Firewall rule updates

## License

MIT
