#!/bin/bash

# Automated deployment to GCP Compute Engine Debian VM
# Creates VM, deploys code, runs app, and opens firewall
# Usage: ./auto-deploy-gcp.sh [project-id] [vm-name] [zone]

set -e

PROJECT_ID=${1:-$GOOGLE_CLOUD_PROJECT}
VM_NAME=${2:-"gemini-agent-vm"}
ZONE=${3:-"us-central1-a"}

if [ -z "$PROJECT_ID" ]; then
    echo "Error: Project ID required"
    echo "Usage: ./auto-deploy-gcp.sh [project-id] [vm-name] [zone]"
    echo "Or set GOOGLE_CLOUD_PROJECT environment variable"
    exit 1
fi

# Validate project and set it explicitly for all commands
echo "Validating project: $PROJECT_ID"
if ! gcloud projects describe $PROJECT_ID &>/dev/null; then
    echo "❌ Project $PROJECT_ID not found or you don't have access"
    exit 1
fi

# Set the project explicitly (overrides any default)
export CLOUDSDK_CORE_PROJECT=$PROJECT_ID
gcloud config set project $PROJECT_ID --quiet

echo "=========================================="
echo "Automated Debian VM Deployment"
echo "=========================================="
echo "Project: $PROJECT_ID (explicitly set)"
echo "VM Name: $VM_NAME"
echo "Zone: $ZONE"
echo ""
echo "Note: All gcloud commands will use project: $PROJECT_ID"
echo ""

# Check if VM already exists
if gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID &>/dev/null; then
    echo "⚠️  VM $VM_NAME already exists. Skipping creation."
    echo "   To recreate, delete it first: gcloud compute instances delete $VM_NAME --zone=$ZONE"
    EXISTING_VM=true
else
    EXISTING_VM=false
fi

# Create VM if it doesn't exist
if [ "$EXISTING_VM" = false ]; then
    echo "Step 1: Checking/creating network..."
    # Check if default network exists, create if not
    if ! gcloud compute networks describe default --project=$PROJECT_ID &>/dev/null; then
        echo "Creating default network..."
        gcloud compute networks create default \
            --subnet-mode=auto \
            --project=$PROJECT_ID
        echo "✓ Default network created"
    else
        echo "✓ Default network exists"
    fi
    echo ""
    
    echo "Step 1b: Configuring firewall rules..."
    # Create SSH firewall rule if it doesn't exist
    if ! gcloud compute firewall-rules describe allow-ssh --project=$PROJECT_ID &>/dev/null; then
        echo "Creating SSH firewall rule..."
        gcloud compute firewall-rules create allow-ssh \
            --allow tcp:22 \
            --source-ranges 0.0.0.0/0 \
            --description "Allow SSH from anywhere" \
            --project=$PROJECT_ID
        echo "✓ SSH firewall rule created"
    else
        echo "✓ SSH firewall rule exists"
    fi
    
    # Create HTTP firewall rule if it doesn't exist
    FIREWALL_RULE="allow-gemini-agent-http"
    if ! gcloud compute firewall-rules describe $FIREWALL_RULE --project=$PROJECT_ID &>/dev/null; then
        echo "Creating HTTP firewall rule (port 80)..."
        gcloud compute firewall-rules create $FIREWALL_RULE \
            --allow tcp:80 \
            --source-ranges 0.0.0.0/0 \
            --target-tags http-server \
            --description "Allow HTTP traffic to Gemini Agent" \
            --project=$PROJECT_ID
        echo "✓ HTTP firewall rule created"
    else
        echo "✓ HTTP firewall rule exists"
    fi
    echo ""
    
    echo "Step 1c: Creating Debian VM..."
    gcloud compute instances create $VM_NAME \
        --zone=$ZONE \
        --machine-type=e2-small \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --boot-disk-size=20GB \
        --tags=http-server,https-server \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --project=$PROJECT_ID
    
    echo "✓ VM created"
    echo ""
    
    # Wait for VM to be ready
    echo "Waiting for VM to be ready (this may take 1-2 minutes)..."
    MAX_WAIT=120  # 2 minutes max
    ELAPSED=0
    SLEEP_INTERVAL=5
    
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT_ID --command="echo 'VM ready'" --quiet &>/dev/null; then
            echo "✓ VM is ready"
            break
        fi
        echo "  Waiting for SSH... (${ELAPSED}s / ${MAX_WAIT}s)"
        sleep $SLEEP_INTERVAL
        ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
    done
    
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo ""
        echo "❌ Timeout waiting for SSH. The VM may still be starting."
        echo "   Check VM status: gcloud compute instances describe $VM_NAME --zone=$ZONE"
        echo "   Try SSH manually: gcloud compute ssh $VM_NAME --zone=$ZONE"
        echo "   If it works, you can continue deployment manually."
        exit 1
    fi
    echo ""
fi

# Get VM external IP
VM_IP=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID --format="get(networkInterfaces[0].accessConfigs[0].natIP)")
echo "VM External IP: $VM_IP"
echo ""

# Package the application
echo "Step 2: Packaging application..."
PACKAGE_DIR="gemini-agent-vm"
PACKAGE_FILE="gemini-agent-vm.tar.gz"
rm -rf $PACKAGE_DIR $PACKAGE_FILE
mkdir -p $PACKAGE_DIR

# Copy necessary files
cp -r app $PACKAGE_DIR/
cp requirements.txt $PACKAGE_DIR/
cp env.sample $PACKAGE_DIR/

# Create tarball
tar -czf $PACKAGE_FILE $PACKAGE_DIR/
rm -rf $PACKAGE_DIR

echo "✓ Application packaged"
echo ""

# Copy package to VM
echo "Step 3: Copying application to VM..."
if ! gcloud compute scp $PACKAGE_FILE $VM_NAME:/tmp/ --zone=$ZONE --project=$PROJECT_ID --quiet; then
    echo "❌ Failed to copy files. Trying again..."
    sleep 5
    gcloud compute scp $PACKAGE_FILE $VM_NAME:/tmp/ --zone=$ZONE --project=$PROJECT_ID
fi
echo "✓ Application copied"
echo ""

# Deploy on VM
echo "Step 4: Deploying application on VM..."
gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT_ID << 'ENDSSH'
set -e
cd /tmp
tar -xzf gemini-agent-vm.tar.gz
cd gemini-agent-vm

# Store the source directory before switching to root
SOURCE_DIR="$(pwd)"

# Deploy Gemini Agent to Debian VM (run as root)
echo "Deploying Gemini Agent to Debian VM..."
echo ""

sudo SOURCE_DIR="$SOURCE_DIR" bash << 'ROOTSCRIPT'
set -e

# Update system
echo "Updating system packages..."
apt-get update
apt-get install -y python3 python3-pip python3-venv git curl libcap2-bin

# Check if we're in the project directory
if [ ! -f "$SOURCE_DIR/requirements.txt" ] || [ ! -d "$SOURCE_DIR/app" ]; then
    echo "Error: Required files not found"
    echo "Source directory: $SOURCE_DIR"
    echo "Expected files: requirements.txt, app/"
    exit 1
fi

# Create app directory
APP_DIR="/opt/gemini-agent"
echo "Creating app directory: $APP_DIR"
mkdir -p $APP_DIR

# Copy application files
echo "Copying application files..."
cp -r $SOURCE_DIR/app $APP_DIR/
cp $SOURCE_DIR/requirements.txt $APP_DIR/
if [ -f $SOURCE_DIR/env.sample ]; then
    cp $SOURCE_DIR/env.sample $APP_DIR/.env.example
fi

cd $APP_DIR

# Create virtual environment
echo "Creating Python virtual environment..."
python3 -m venv $APP_DIR/venv
source $APP_DIR/venv/bin/activate

# Install dependencies
echo "Installing Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/gemini-agent.service <<EOFSERVICE
[Unit]
Description=Gemini Agent FastAPI Application
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin"
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 80
Restart=always
RestartSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOFSERVICE

# Create .env file if it doesn't exist
if [ ! -f "$APP_DIR/.env" ]; then
    echo "Creating .env file from template..."
    cp $APP_DIR/.env.example $APP_DIR/.env
    
    # Try to auto-detect GCP project from metadata server
    GCP_PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || echo "")
    if [ -n "$GCP_PROJECT" ]; then
        echo "Auto-detected GCP project: $GCP_PROJECT"
        sed -i "s/^GOOGLE_CLOUD_PROJECT=$/GOOGLE_CLOUD_PROJECT=$GCP_PROJECT/" $APP_DIR/.env
    fi
fi

# Set permissions
echo "Setting permissions..."
chown -R www-data:www-data $APP_DIR
chmod +x $APP_DIR/venv/bin/uvicorn

# Allow uvicorn to bind to port 80 (requires setcap)
echo "Configuring port 80 access..."
if command -v setcap &> /dev/null; then
    setcap 'cap_net_bind_service=+ep' $APP_DIR/venv/bin/uvicorn
    echo "✓ Port 80 access configured via setcap"
else
    echo "⚠️  setcap not found. Installing libcap2-bin..."
    apt-get install -y libcap2-bin
    setcap 'cap_net_bind_service=+ep' $APP_DIR/venv/bin/uvicorn
    echo "✓ Port 80 access configured"
fi

# Configure firewall (allow port 80)
echo "Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    echo "✓ UFW firewall configured"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --reload
    echo "✓ firewalld configured"
else
    echo "⚠️  No firewall manager found. Please manually allow port 80"
fi

# Enable and start service
echo "Enabling and starting service..."
systemctl daemon-reload
systemctl enable gemini-agent
systemctl start gemini-agent

echo ""
echo "✓ Deployment complete!"
ROOTSCRIPT
ENDSSH

echo "✓ Application deployed"
echo ""

# Verify firewall rules (already created in Step 1b)
echo "Step 5: Verifying firewall rules..."
FIREWALL_RULE="allow-gemini-agent-http"
if gcloud compute firewall-rules describe $FIREWALL_RULE --project=$PROJECT_ID &>/dev/null; then
    echo "✓ HTTP firewall rule is configured"
else
    echo "⚠️  HTTP firewall rule missing, creating now..."
    gcloud compute firewall-rules create $FIREWALL_RULE \
        --allow tcp:80 \
        --source-ranges 0.0.0.0/0 \
        --target-tags http-server \
        --description "Allow HTTP traffic to Gemini Agent" \
        --project=$PROJECT_ID
    echo "✓ HTTP firewall rule created"
fi
echo ""

# Wait a moment for service to start
echo "Waiting for service to start..."
sleep 5

# Test the deployment
echo "Step 6: Testing deployment..."
if curl -s --max-time 5 http://$VM_IP/health &>/dev/null; then
    echo "✓ Service is responding!"
else
    echo "⚠️  Service may still be starting. Check logs:"
    echo "   gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo journalctl -u gemini-agent -n 20'"
fi
echo ""

echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "VM Details:"
echo "  Name: $VM_NAME"
echo "  Zone: $ZONE"
echo "  IP: $VM_IP"
echo ""
echo "Access the application:"
echo "  Web UI: http://$VM_IP/"
echo "  API: http://$VM_IP/api/chat"
echo "  Health: http://$VM_IP/health"
echo ""
echo "Useful commands:"
echo "  SSH to VM: gcloud compute ssh $VM_NAME --zone=$ZONE"
echo "  View logs: gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo journalctl -u gemini-agent -f'"
echo "  Restart: gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo systemctl restart gemini-agent'"
echo "  Delete VM: gcloud compute instances delete $VM_NAME --zone=$ZONE"
echo ""

