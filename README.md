# Gemini Agent App

A Python FastAPI application that uses Google Gemini with function-calling and popular tools:
- Web search (DuckDuckGo Instant Answer)
- Fetch URL and extract readable text
- Safe calculator

## Features

- **Automatic Vertex AI detection**: Uses Vertex AI with Application Default Credentials (no API key needed)
- **Tool calling**: Web search, URL fetching, and calculator tools
- **Web UI**: Simple web interface for testing
- **Real-time logging**: Monitor API requests and responses in real-time
- **Automated deployment**: One-command deployment to GCP Compute Engine

## Requirements

- `gcloud` CLI configured with appropriate permissions
- GCP project with Vertex AI API enabled
- Service account with `roles/aiplatform.user` role

## Configuration

The application automatically detects the GCP project when deployed to a VM. No manual configuration needed - the deployment script handles:
- Auto-detection of `GOOGLE_CLOUD_PROJECT` from the metadata server
- Vertex AI initialization with Application Default Credentials
- Firewall rules configuration with auto-detected source IP

## Deployment

### Deploy to GCP VM

The automated deployment script creates a VM, configures firewall rules, and deploys the application:

```bash
./auto-deploy-gcp.sh [project-id] [vm-name] [zone] [your-ip]
```

**Arguments:**
- `project-id`: GCP project ID (required)
- `vm-name`: VM name (default: `gemini-agent-vm`)
- `zone`: GCP zone (default: `us-central1-a`)
- `your-ip`: Your public IP address (optional, auto-detected)

**Examples:**

From Cloud Shell (IP auto-detected):
```bash
./auto-deploy-gcp.sh airs20-poc
```

With explicit parameters:
```bash
./auto-deploy-gcp.sh airs20-poc gemini-agent-vm us-central1-a
```

With explicit IP:
```bash
./auto-deploy-gcp.sh airs20-poc gemini-agent-vm us-central1-a 203.0.113.1
```

**What the script does:**
1. Checks for updates from GitHub
2. Auto-detects source IP (Cloud Shell or local machine)
3. Creates/updates firewall rules (allows your IP + GCP health checker)
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
  "text": "The answer is 4.",
  "tools": [
    {
      "name": "calculator",
      "args": {"expression": "2+2"},
      "result": "4"
    }
  ]
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
2. Update firewall with your IP: `gcloud compute firewall-rules update allow-gemini-agent-http --source-ranges YOUR_IP/32,35.197.73.227/32`

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
