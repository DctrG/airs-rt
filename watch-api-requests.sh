#!/bin/bash

# Watch HTTP requests to /api/chat endpoint in real-time
# Usage: ./watch-api-requests.sh [vm-name] [zone] [project-id]

VM_NAME=${1:-"gemini-agent-vm"}
ZONE=${2:-"us-central1-a"}
PROJECT_ID=${3:-$GOOGLE_CLOUD_PROJECT}

if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    if [ -z "$PROJECT_ID" ]; then
        echo "Error: Project ID required"
        echo "Usage: ./watch-api-requests.sh [vm-name] [zone] [project-id]"
        exit 1
    fi
fi

echo "Watching HTTP requests to /api/chat endpoint"
echo "VM: $VM_NAME"
echo "Zone: $ZONE"
echo "Project: $PROJECT_ID"
echo ""
echo "Press Ctrl+C to stop"
echo "=========================================="
echo ""

# Follow journal logs and filter for /api/chat requests
gcloud compute ssh $VM_NAME \
    --zone=$ZONE \
    --project=$PROJECT_ID \
    --command="sudo journalctl -u gemini-agent -f --no-pager" \
    2>&1 | grep --line-buffered -E "(POST|GET).*\/api\/chat|REQUEST|RESPONSE|TOOL_CALL|TOOL_RESULT" || \
gcloud compute ssh $VM_NAME \
    --zone=$ZONE \
    --project=$PROJECT_ID \
    --command="sudo journalctl -u gemini-agent -f --no-pager"

