# AI Agent App

A Python FastAPI application implementing an AI agent that uses Google Gemini with function-calling and popular tools:
- Web search (DuckDuckGo Instant Answer)
- Fetch URL and extract readable text
- Safe calculator

## Features

- **Automatic Vertex AI detection**: Uses Vertex AI with Application Default Credentials (no API key needed when running in GCP)
- **Tool calling**: Web search, URL fetching, and calculator tools
- **Web UI**: Simple web interface for testing
- **Real-time logging**: Monitor API requests and responses in real-time with detailed headers and status codes
- **Automated deployment**: One-command deployment to GCP Compute Engine with automatic setup
- **Model fallback**: Automatically falls back to compatible models if the default model is unavailable

## Configuration

The application automatically detects the GCP project when deployed to a VM. No manual configuration needed - the deployment script handles everything:

- Auto-detection of `GOOGLE_CLOUD_PROJECT` from the metadata server
- Vertex AI initialization with Application Default Credentials
- Firewall rules configuration with auto-detected Cloud Shell IP
- Required API enablement (Compute Engine and Vertex AI)
- Service account permission setup (`roles/aiplatform.user`)

## Deployment

### Prerequisites

- GCP project with billing enabled
- `gcloud` CLI installed and authenticated
- Run the script from GCP Cloud Shell (recommended) or a machine with `gcloud` configured

### Deploy to GCP VM

Run the deployment script from Cloud Shell:

```bash
./deploy.sh [project-id] [vm-name] [zone]
```

**Arguments:**
- `project-id`: GCP project ID (required)
- `vm-name`: VM name (default: `gemini-agent-vm`)
- `zone`: GCP zone (default: `us-central1-a`)

**Examples:**

Basic deployment:
```bash
./deploy.sh airs20-poc
```

With custom VM name and zone:
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

### Default Model

The application uses `gemini-2.0-flash` by default. If this model is not available in Vertex AI, it automatically falls back to:
- `gemini-1.5-flash-exp`
- `gemini-1.5-flash`
- `gemini-1.5-pro`

You can override the default by setting the `GEMINI_MODEL` environment variable.

## Usage

### Web Interface

Once deployed, access the web UI at:
```
http://your-vm-ip/
```

The web interface provides a simple chat interface for testing the agent.

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

**HTTP Status Codes:**
- `200 OK`: Successful request
- `400 Bad Request`: Invalid request (e.g., empty prompt)
- `500 Internal Server Error`: Server error (check logs for details)

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

## Troubleshooting

### Firewall Issues

If you can't access the application:

1. Check firewall rules:
   ```bash
   gcloud compute firewall-rules describe allow-gemini-agent-http --project=YOUR_PROJECT_ID
   ```

2. The script automatically updates the firewall with Cloud Shell's IP on each run

3. To add a new IP address to the firewall (preserves existing IPs):
   ```bash
   CURRENT_IPS=$(gcloud compute firewall-rules describe allow-gemini-agent-http --project=YOUR_PROJECT_ID --format='get(sourceRanges.list())' | tr ';' ',' | sed 's/,$//')
   gcloud compute firewall-rules update allow-gemini-agent-http --source-ranges "$CURRENT_IPS,YOUR_NEW_IP/32" --project=YOUR_PROJECT_ID
   ```

### Vertex AI Permissions

If you get permission errors:

1. Ensure the VM service account has `roles/aiplatform.user`:
   ```bash
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
     --role="roles/aiplatform.user"
   ```

2. Check that the VM has the `https://www.googleapis.com/auth/cloud-platform` scope (automatically set by the deployment script)

3. Wait a few minutes for IAM changes to propagate

### API Not Enabled

If you see errors about APIs not being enabled:

The deployment script automatically enables required APIs, but if you need to enable them manually:

```bash
gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com --project=YOUR_PROJECT_ID
```

### View Logs

SSH to the VM and check service logs:
```bash
gcloud compute ssh gemini-agent-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
sudo journalctl -u gemini-agent -f
```

### Restart Service

```bash
gcloud compute ssh gemini-agent-vm --zone=us-central1-a --project=YOUR_PROJECT_ID --command="sudo systemctl restart gemini-agent"
```

### Check Service Status

```bash
gcloud compute ssh gemini-agent-vm --zone=us-central1-a --project=YOUR_PROJECT_ID --command="sudo systemctl status gemini-agent"
```

### Delete VM

To completely remove the deployment:

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
