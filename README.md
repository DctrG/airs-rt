# AI Agent App

A Python FastAPI application implementing an AI agent that uses Google Gemini with function-calling and popular tools:
- Web search (DuckDuckGo Instant Answer)
- Fetch URL and extract readable text
- Safe calculator

## Features

- **Automatic Vertex AI detection**: Uses Vertex AI with Application Default Credentials (no API key needed)
- **Tool calling**: Web search, URL fetching, and calculator tools
- **Web UI**: Simple web interface for testing
- **Real-time logging**: Monitor API requests and responses in real-time
- **Automated deployment**: One-command deployment to GCP Compute Engine

## Configuration

The application automatically detects the GCP project when deployed to a VM. No manual configuration needed - the deployment script handles:
- Auto-detection of `GOOGLE_CLOUD_PROJECT` from the metadata server
- Vertex AI initialization with Application Default Credentials
- Firewall rules configuration with auto-detected Cloud Shell IP

## Deployment

### Deploy to GCP VM

Run the deployment script from Cloud Shell:

```bash
./auto-deploy-gcp.sh [project-id] [vm-name] [zone]
```

**Arguments:**
- `project-id`: GCP project ID (required)
- `vm-name`: VM name (default: `gemini-agent-vm`)
- `zone`: GCP zone (default: `us-central1-a`)

**Examples:**

Basic deployment:
```bash
./auto-deploy-gcp.sh airs20-poc
```

With custom VM name and zone:
```bash
./auto-deploy-gcp.sh airs20-poc my-gemini-vm us-central1-b
```

**What the script does:**
1. Checks for updates from GitHub
2. Auto-detects Cloud Shell's external IP
3. Creates/updates firewall rules (allows Cloud Shell IP + GCP health checker)
4. Creates Debian VM if it doesn't exist
5. Deploys application code
6. Configures systemd service
7. Tests health and API endpoints
8. Provides access URLs and test commands

## Usage

### Web Interface

Once deployed, access the web UI at:
```
http://your-vm-ip/
```

### API Endpoint

Send requests to the `/api/chat` endpoint:

```bash
curl -X POST http://your-vm-ip/api/chat \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2+2?"}'
```

**Response format:**
```json
{
  "text": "2+2 is 4."
}
```

### AIRS RT Setup

**Curl command:**
```bash
curl \
  "http://your-vm-ip/api/chat" \
  -H "Content-Type: application/json" \
  --data '{"prompt":"{INPUT}"}'
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
│   │       ├── webSearch.py
│   │       ├── fetchUrl.py
│   │       └── calculator.py
│   └── templates/         # Web UI
│       └── index.html
├── auto-deploy-gcp.sh     # Automated GCP deployment
├── watch-api-requests.sh  # Monitor API requests
├── requirements.txt       # Python dependencies
└── README.md             # This file
```

## Troubleshooting

### Firewall Issues

If you can't access the application:
1. Check firewall rules: `gcloud compute firewall-rules describe allow-gemini-agent-http`
2. The script automatically updates the firewall with Cloud Shell's IP on each run

### Vertex AI Permissions

If you get permission errors:
1. Ensure the VM service account has `roles/aiplatform.user`
2. Check that the VM has the `https://www.googleapis.com/auth/cloud-platform` scope

### View Logs

SSH to the VM and check service logs:
```bash
gcloud compute ssh gemini-agent-vm --zone=us-central1-a
sudo journalctl -u gemini-agent -f
```

### Restart Service

```bash
gcloud compute ssh gemini-agent-vm --zone=us-central1-a --command="sudo systemctl restart gemini-agent"
```

## License

MIT
