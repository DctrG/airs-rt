#!/bin/bash

# Automated deployment to GCP Compute Engine Debian VM
# Creates VM, deploys code, runs app, and opens firewall
# Usage: ./auto-deploy-gcp.sh [project-id] [vm-name] [zone] [your-ip]

set -e

PROJECT_ID=${1:-$GOOGLE_CLOUD_PROJECT}
VM_NAME=${2:-"gemini-agent-vm"}
ZONE=${3:-"us-central1-a"}
USER_IP=${4:-""}

if [ -z "$PROJECT_ID" ]; then
    echo "Error: Project ID required"
    echo "Usage: ./auto-deploy-gcp.sh [project-id] [vm-name] [zone] [your-ip]"
    echo "Or set GOOGLE_CLOUD_PROJECT environment variable"
    echo ""
    echo "Arguments:"
    echo "  project-id: GCP project ID (required)"
    echo "  vm-name:   VM name (default: gemini-agent-vm)"
    echo "  zone:      GCP zone (default: us-central1-a)"
    echo "  your-ip:   Your public IP address for firewall (optional, will auto-detect)"
    echo "             - Auto-detects Cloud Shell IP when running from Cloud Shell"
    echo "             - Auto-detects your IP when running from local machine"
    exit 1
fi

# Auto-detect user IP if not provided
if [ -z "$USER_IP" ]; then
    echo "Auto-detecting source IP address..."
    
    # Check if running from Cloud Shell
    IS_CLOUD_SHELL=false
    if [ -n "$CLOUD_SHELL" ] || [ -n "$CLOUDSHELL_ENVIRONMENT" ] || echo "$HOSTNAME" | grep -q "cloudshell"; then
        IS_CLOUD_SHELL=true
        echo "  Detected: Running from GCP Cloud Shell"
    fi
    
    # Try to get IP address
    if [ "$IS_CLOUD_SHELL" = true ]; then
        # In Cloud Shell, try multiple methods to get the external IP
        echo "  Attempting to get Cloud Shell's external IP..."
        
        # Method 1: Try GCP metadata server (works in Compute Engine, may work in Cloud Shell)
        USER_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || echo "")
        
        # Method 2: Try external service if metadata server didn't work
        if [ -z "$USER_IP" ]; then
            USER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null || echo "")
        fi
        
        if [ -n "$USER_IP" ]; then
            echo "✓ Detected Cloud Shell IP: $USER_IP"
            SOURCE_RANGES="$USER_IP/32,35.197.73.227/32"
        else
            echo "⚠️  Could not detect Cloud Shell IP. Firewall will allow all traffic."
            SOURCE_RANGES="0.0.0.0/0"
        fi
    else
        # Not in Cloud Shell, get local machine's IP using external services
        USER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null || echo "")
        if [ -z "$USER_IP" ]; then
            echo "⚠️  Could not auto-detect your IP. Firewall will allow all traffic."
            echo "   You can manually update the firewall rule later with:"
            echo "   gcloud compute firewall-rules update allow-gemini-agent-http --source-ranges YOUR_IP/32,35.197.73.227/32"
            SOURCE_RANGES="0.0.0.0/0"
        else
            echo "✓ Detected your IP: $USER_IP"
            SOURCE_RANGES="$USER_IP/32,35.197.73.227/32"
        fi
    fi
else
    # Validate IP format if provided
    if [[ $USER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        SOURCE_RANGES="$USER_IP/32,35.197.73.227/32"
        echo "Using provided IP: $USER_IP"
    else
        echo "⚠️  Invalid IP format: $USER_IP"
        echo "   Expected format: X.X.X.X (e.g., 192.168.1.1)"
        echo "   Firewall will allow all traffic."
        SOURCE_RANGES="0.0.0.0/0"
    fi
fi

# GCP health checker IP (always included)
GCP_HEALTH_CHECKER="35.197.73.227/32"

# Check for updates from GitHub
echo "Checking for updates from GitHub..."
if [ -d ".git" ]; then
    # Fetch latest changes without merging
    git fetch origin main &>/dev/null
    
    # Check if local is behind remote
    LOCAL=$(git rev-parse @ 2>/dev/null)
    REMOTE=$(git rev-parse @{u} 2>/dev/null 2>/dev/null || echo "")
    
    if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
        echo "⚠️  GitHub repository has newer commits"
        echo "   Local:  $LOCAL"
        echo "   Remote: $REMOTE"
        echo "   Pulling latest changes..."
        if git pull origin main; then
            echo "✓ Successfully updated from GitHub"
            echo "  Continuing with deployment using updated code..."
        else
            echo "⚠️  Failed to pull updates. Continuing with current version..."
        fi
    else
        echo "✓ Repository is up to date"
    fi
else
    echo "⚠️  Not a git repository. Skipping update check."
fi
echo ""

# Validate project and set it explicitly for all commands
echo "Validating project: $PROJECT_ID"
if ! gcloud projects describe $PROJECT_ID &>/dev/null; then
    echo "❌ Project $PROJECT_ID not found or you don't have access"
    exit 1
fi

# Set the project explicitly (overrides any default)
export CLOUDSDK_CORE_PROJECT=$PROJECT_ID
gcloud config set project $PROJECT_ID --quiet

# Check and enable required APIs
echo "Step 0: Checking required APIs..."
REQUIRED_APIS=(
    "compute.googleapis.com"
    "aiplatform.googleapis.com"
)

for API in "${REQUIRED_APIS[@]}"; do
    API_NAME=$(echo $API | cut -d'.' -f1)
    if gcloud services list --enabled --project=$PROJECT_ID --filter="name:$API" --format="value(name)" | grep -q "^$API$"; then
        echo "✓ $API_NAME API is enabled"
    else
        echo "⚠️  $API_NAME API is not enabled. Enabling now..."
        if gcloud services enable $API --project=$PROJECT_ID; then
            echo "✓ $API_NAME API enabled"
        else
            echo "❌ Failed to enable $API_NAME API"
            echo "   Please enable it manually: gcloud services enable $API --project=$PROJECT_ID"
            exit 1
        fi
    fi
done
echo ""

# Get the default Compute Engine service account email
# Format: PROJECT_NUMBER-compute@developer.gserviceaccount.com
echo "Step 0b: Determining service account..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)" 2>/dev/null || echo "")
if [ -n "$PROJECT_NUMBER" ]; then
    COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
    echo "  Project number: $PROJECT_NUMBER"
    echo "  Default service account: $COMPUTE_SA"
else
    echo "  ⚠️  Could not get project number, trying alternative method..."
    # Fallback: try to get from IAM service accounts list
    COMPUTE_SA=$(gcloud iam service-accounts list --project=$PROJECT_ID --filter="displayName:Compute Engine default service account" --format="value(email)" --limit=1 2>/dev/null || echo "")
    if [ -n "$COMPUTE_SA" ]; then
        echo "  Found service account via IAM list: $COMPUTE_SA"
    else
        # Last resort: use project number format (will be validated when granting permission)
        echo "  ⚠️  Could not determine default service account, will use VM's service account"
        COMPUTE_SA=""
    fi
fi
echo ""

echo "Checking service account permissions..."

# Check if VM exists to determine which service account to check
if gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID &>/dev/null 2>&1; then
    # VM exists, get its actual service account
    VM_SA=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID --format="get(serviceAccounts[0].email)" 2>/dev/null || echo "")
    if [ -n "$VM_SA" ]; then
        echo "  Using VM's service account: $VM_SA"
        SA_TO_CHECK="$VM_SA"
    elif [ -n "$COMPUTE_SA" ]; then
        echo "  Using default Compute Engine service account: $COMPUTE_SA"
        SA_TO_CHECK="$COMPUTE_SA"
    else
        echo "⚠️  Could not determine service account. Skipping permission check."
        echo "   You may need to grant roles/aiplatform.user manually after VM creation."
        SA_TO_CHECK=""
    fi
else
    # VM doesn't exist yet, use default service account
    if [ -n "$COMPUTE_SA" ]; then
        echo "  Service account: $COMPUTE_SA"
        SA_TO_CHECK="$COMPUTE_SA"
    else
        echo "⚠️  Could not determine default service account. Will check after VM creation."
        SA_TO_CHECK=""
    fi
fi

# Check if service account has aiplatform.user role (only if we have a service account to check)
if [ -n "$SA_TO_CHECK" ]; then
    PERMISSION_CHECK=$(gcloud projects get-iam-policy $PROJECT_ID --flatten="bindings[].members" --filter="bindings.members:serviceAccount:$SA_TO_CHECK AND bindings.role:roles/aiplatform.user" --format="value(bindings.role)" 2>/dev/null)
    if echo "$PERMISSION_CHECK" | grep -q "roles/aiplatform.user"; then
        echo "✓ Service account has roles/aiplatform.user permission"
    else
        echo "⚠️  Service account missing roles/aiplatform.user permission. Attempting to grant..."
        GRANT_OUTPUT=$(gcloud projects add-iam-policy-binding $PROJECT_ID \
            --member="serviceAccount:$SA_TO_CHECK" \
            --role="roles/aiplatform.user" \
            --condition=None 2>&1)
        GRANT_EXIT_CODE=$?
        
        if [ $GRANT_EXIT_CODE -eq 0 ]; then
            echo "✓ Granted roles/aiplatform.user to service account"
            echo "  Note: IAM changes may take a few minutes to propagate"
        else
            echo "⚠️  Could not automatically grant roles/aiplatform.user permission"
            echo "   Error: $GRANT_OUTPUT"
            echo ""
            echo "   This usually means you don't have IAM admin permissions."
            echo "   Please ask a project admin to grant the permission manually:"
            echo ""
            echo "   gcloud projects add-iam-policy-binding $PROJECT_ID \\"
            echo "     --member=\"serviceAccount:$SA_TO_CHECK\" \\"
            echo "     --role=\"roles/aiplatform.user\""
            echo ""
            echo "   Or continue deployment and grant it later. The app will work"
            echo "   once the permission is granted (may take a few minutes to propagate)."
            echo ""
            read -p "Continue with deployment? (y/n) " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Deployment cancelled."
                exit 0
            fi
        fi
    fi
else
    echo "⚠️  Skipping permission check (service account will be checked after VM creation)"
fi
echo ""

echo "=========================================="
echo "Automated Debian VM Deployment"
echo "=========================================="
echo "Project: $PROJECT_ID (explicitly set)"
echo "VM Name: $VM_NAME"
echo "Zone: $ZONE"
if [ "$SOURCE_RANGES" != "0.0.0.0/0" ]; then
    echo "Allowed IPs: $SOURCE_RANGES"
fi
echo ""
echo "Note: All gcloud commands will use project: $PROJECT_ID"
echo ""

# Step 1: Configure firewall rules (always do this, regardless of VM existence)
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

# Always update HTTP firewall rule with current detected IP
FIREWALL_RULE="allow-gemini-agent-http"
echo "  Detected source IP: $USER_IP"
echo "  Source ranges: $SOURCE_RANGES"
if ! gcloud compute firewall-rules describe $FIREWALL_RULE --project=$PROJECT_ID &>/dev/null; then
    echo "Creating HTTP firewall rule (port 80)..."
    gcloud compute firewall-rules create $FIREWALL_RULE \
        --allow tcp:80 \
        --source-ranges "$SOURCE_RANGES" \
        --target-tags http-server \
        --description "Allow HTTP traffic to Gemini Agent" \
        --project=$PROJECT_ID
    echo "✓ HTTP firewall rule created"
else
    echo "✓ HTTP firewall rule exists"
    echo "  Updating source ranges to: $SOURCE_RANGES"
    gcloud compute firewall-rules update $FIREWALL_RULE \
        --source-ranges "$SOURCE_RANGES" \
        --project=$PROJECT_ID
    echo "✓ Firewall rule updated with detected IP: $USER_IP"
fi
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
    
    echo "Step 1c: Creating Debian VM..."
    gcloud compute instances create $VM_NAME \
        --zone=$ZONE \
        --machine-type=e2-small \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --boot-disk-size=15GB \
        --tags=http-server,https-server \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --project=$PROJECT_ID \
        --quiet
    
    echo "✓ VM created"
    echo ""
    
    # Verify service account permissions for the newly created VM
    echo "Verifying service account permissions..."
    VM_SA=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID --format="get(serviceAccounts[0].email)" 2>/dev/null || echo "$COMPUTE_SA")
    echo "  VM service account: $VM_SA"
    
    # Check if service account has aiplatform.user role (with retry for IAM propagation)
    PERMISSION_GRANTED=false
    for i in {1..3}; do
        if gcloud projects get-iam-policy $PROJECT_ID --flatten="bindings[].members" --filter="bindings.members:serviceAccount:$VM_SA AND bindings.role:roles/aiplatform.user" --format="value(bindings.role)" 2>/dev/null | grep -q "roles/aiplatform.user"; then
            echo "✓ VM service account has required permissions"
            PERMISSION_GRANTED=true
            break
        else
            if [ $i -eq 1 ]; then
                echo "⚠️  Granting roles/aiplatform.user to VM service account..."
                GRANT_OUTPUT=$(gcloud projects add-iam-policy-binding $PROJECT_ID \
                    --member="serviceAccount:$VM_SA" \
                    --role="roles/aiplatform.user" \
                    --condition=None 2>&1)
                GRANT_EXIT_CODE=$?
                
                if [ $GRANT_EXIT_CODE -eq 0 ]; then
                    echo "✓ Permission granted, waiting for IAM propagation..."
                    sleep 10  # Wait for IAM propagation
                else
                    echo "⚠️  Could not automatically grant permissions: $GRANT_OUTPUT"
                    echo "   Please grant manually:"
                    echo "   gcloud projects add-iam-policy-binding $PROJECT_ID \\"
                    echo "     --member=\"serviceAccount:$VM_SA\" \\"
                    echo "     --role=\"roles/aiplatform.user\""
                    break
                fi
            else
                echo "  Waiting for IAM propagation... (attempt $i/3)"
                sleep 5
            fi
        fi
    done
    
    if [ "$PERMISSION_GRANTED" = false ]; then
        echo "⚠️  Warning: Could not verify permissions. IAM changes may take a few minutes to propagate."
        echo "   If you encounter permission errors, wait a few minutes and try again."
        echo "   Or grant manually: gcloud projects add-iam-policy-binding $PROJECT_ID --member=\"serviceAccount:$VM_SA\" --role=\"roles/aiplatform.user\""
    fi
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
    echo "Creating .env file..."
    # Try to auto-detect GCP project from metadata server
    GCP_PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || echo "")
    if [ -n "$GCP_PROJECT" ]; then
        echo "Auto-detected GCP project: $GCP_PROJECT"
        echo "GOOGLE_CLOUD_PROJECT=$GCP_PROJECT" > $APP_DIR/.env
    else
        # Create empty .env file if project detection fails
        touch $APP_DIR/.env
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

# Configure local firewall (allow port 80)
# Note: GCP firewall rules handle external access, this is for local VM firewall
echo "Configuring local firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp &>/dev/null
    echo "✓ UFW firewall configured"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=80/tcp &>/dev/null
    firewall-cmd --reload &>/dev/null
    echo "✓ firewalld configured"
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
    CURRENT_RANGES=$(gcloud compute firewall-rules describe $FIREWALL_RULE --project=$PROJECT_ID --format="get(sourceRanges.list())" 2>/dev/null)
    echo "✓ HTTP firewall rule is configured"
    echo "  Current allowed IPs: $CURRENT_RANGES"
else
    echo "⚠️  HTTP firewall rule missing, creating now..."
    echo "  Allowing traffic from: $SOURCE_RANGES"
    gcloud compute firewall-rules create $FIREWALL_RULE \
        --allow tcp:80 \
        --source-ranges "$SOURCE_RANGES" \
        --target-tags http-server \
        --description "Allow HTTP traffic to Gemini Agent" \
        --project=$PROJECT_ID
    echo "✓ HTTP firewall rule created"
fi
echo ""

# Wait for service to start
echo "Step 6: Waiting for service to start..."
echo "Checking service status..."
MAX_WAIT=30
ELAPSED=0
SLEEP_INTERVAL=2

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -s --max-time 3 http://$VM_IP/health &>/dev/null; then
        echo "✓ Service is ready!"
        break
    fi
    echo "  Waiting for service... (${ELAPSED}s / ${MAX_WAIT}s)"
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "⚠️  Service may still be starting. Continuing with tests..."
fi
echo ""

# Test health endpoint
echo "Step 7: Testing health endpoint..."
HEALTH_RESPONSE=$(curl -s --max-time 5 http://$VM_IP/health 2>&1)
if [ $? -eq 0 ] && echo "$HEALTH_RESPONSE" | grep -q "ok\|status"; then
    echo "✓ Health check passed!"
    echo "  Response: $HEALTH_RESPONSE"
else
    echo "⚠️  Health check failed"
    echo "  Response: $HEALTH_RESPONSE"
fi
echo ""

# Test API endpoint with actual request
echo "Step 8: Testing API endpoint..."
echo "Sending test request: 'What is 2+2?'"
TEST_RESPONSE=$(curl -s --max-time 15 -X POST http://$VM_IP/api/chat \
    -H "Content-Type: application/json" \
    -d '{"prompt": "What is 2+2?"}' 2>&1)

if [ $? -eq 0 ]; then
    if echo "$TEST_RESPONSE" | grep -q "text\|error"; then
        echo "✓ API endpoint is responding!"
        echo "Response preview (first 300 chars):"
        echo "$TEST_RESPONSE" | head -c 300
        echo ""
        echo ""
        # Check if there's an error
        if echo "$TEST_RESPONSE" | grep -q '"error"'; then
            echo "⚠️  API returned an error (check Vertex AI permissions if using GCP)"
        fi
    else
        echo "⚠️  Unexpected API response format"
        echo "Response: $TEST_RESPONSE"
    fi
else
    echo "⚠️  API test failed (connection error)"
    echo "Response: $TEST_RESPONSE"
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
echo "Test the API:"
echo "  curl -X POST http://$VM_IP/api/chat \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"prompt\": \"What is 2+2?\"}'"
echo ""
echo "Useful commands:"
echo "  SSH to VM: gcloud compute ssh $VM_NAME --zone=$ZONE"
echo "  View logs: gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo journalctl -u gemini-agent -f'"
echo "  Restart: gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo systemctl restart gemini-agent'"
echo "  Delete VM: gcloud compute instances delete $VM_NAME --zone=$ZONE"
echo ""

