#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================

# SOURCE: Sonatype Nexus
NEXUS_BASE_URL="http://128.140.89.42:8081"
NEXUS_REPO_NAME="c4e"
NEXUS_USER="admin"
NEXUS_PASS="Admin123"

# TARGET: JFrog Artifactory OSS
ART_BASE_URL="http://65.109.137.18:8082/artifactory"
ART_REPO_NAME="libs-release-local" # ENSURE THIS REPO EXISTS IN ARTIFACTORY
ART_USER="admin"
ART_PASS="Admin123"

# TEMP DIRECTORY
WORK_DIR="./migration_temp"

# ==========================================
# MIGRATION LOGIC
# ==========================================

# 1. Check for jq
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' is not installed. Please install it (e.g., sudo apt install jq)."
    exit 1
fi

# 2. Pre-flight Check: Verify Artifactory Repo Exists
echo "[CHECK] Verifying target repository: $ART_REPO_NAME..."
REPO_CHECK_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$ART_USER:$ART_PASS" "$ART_BASE_URL/api/repositories/$ART_REPO_NAME")

if [[ "$REPO_CHECK_CODE" == "400" || "$REPO_CHECK_CODE" == "404" ]]; then
    echo "[CRITICAL ERROR] Repository '$ART_REPO_NAME' does not exist in Artifactory."
    echo "Please log in to Artifactory -> Admin -> Repositories -> Local -> New -> Maven."
    echo "Create a repository named '$ART_REPO_NAME' and try again."
    exit 1
elif [[ "$REPO_CHECK_CODE" == "401" || "$REPO_CHECK_CODE" == "403" ]]; then
     echo "[CRITICAL ERROR] Authentication failed for Artifactory. Check your username/password."
     exit 1
fi

mkdir -p "$WORK_DIR"

echo "=========================================="
echo " STARTING MIGRATION: $NEXUS_REPO_NAME -> $ART_REPO_NAME"
echo "=========================================="

CONTINUATION_TOKEN=""

while true; do
    # Construct API URL
    API_URL="${NEXUS_BASE_URL}/service/rest/v1/assets?repository=${NEXUS_REPO_NAME}"
    if [ ! -z "$CONTINUATION_TOKEN" ] && [ "$CONTINUATION_TOKEN" != "null" ]; then
        API_URL="${API_URL}&continuationToken=${CONTINUATION_TOKEN}"
    fi

    echo "[INFO] Fetching asset list from Nexus..."
    
    # Fetch JSON response
    RESPONSE=$(curl -s -u "$NEXUS_USER:$NEXUS_PASS" "$API_URL")
    
    # Check if Nexus Login worked
    if echo "$RESPONSE" | grep -q "401"; then
        echo "[ERROR] Failed to authenticate with Nexus. Check Nexus username/password."
        exit 1
    fi

    # Extract Items (DownloadURL and Path) safely using jq
    # Format: URL <tab> PATH
    echo "$RESPONSE" | jq -r '.items[] | "\(.downloadUrl)\t\(.path)"' | while IFS=$'\t' read -r DOWNLOAD_URL ARTIFACT_PATH; do
        
        LOCAL_FILE="$WORK_DIR/$(basename "$ARTIFACT_PATH")"
        
        # A. DOWNLOAD
        # echo "[DOWN] Downloading $ARTIFACT_PATH..."
        curl -s -u "$NEXUS_USER:$NEXUS_PASS" -o "$LOCAL_FILE" "$DOWNLOAD_URL"
        
        if [ ! -f "$LOCAL_FILE" ]; then
            echo "[ERROR] Failed to download $ARTIFACT_PATH"
            continue
        fi

        # B. CALCULATE CHECKSUM
        CHECKSUM=$(sha1sum "$LOCAL_FILE" | awk '{print $1}')

        # C. UPLOAD TO ARTIFACTORY
        TARGET_URL="${ART_BASE_URL}/${ART_REPO_NAME}/${ARTIFACT_PATH}"
        echo "[UPLOAD] Processing: $ARTIFACT_PATH"
        
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "$ART_USER:$ART_PASS" \
            -H "X-Checksum-Sha1: $CHECKSUM" \
            -T "$LOCAL_FILE" \
            "$TARGET_URL")

        if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
            echo "[SUCCESS] Uploaded $ARTIFACT_PATH"
        else
            echo "[ERROR] Upload failed for $ARTIFACT_PATH (HTTP $HTTP_CODE)"
        fi

        # D. CLEANUP
        rm "$LOCAL_FILE"

    done

    # Check for next page
    CONTINUATION_TOKEN=$(echo "$RESPONSE" | jq -r '.continuationToken')
    
    if [ "$CONTINUATION_TOKEN" == "null" ] || [ -z "$CONTINUATION_TOKEN" ]; then
        echo "=========================================="
        echo " NO MORE PAGES. MIGRATION COMPLETE."
        echo "=========================================="
        break
    fi
done

rm -rf "$WORK_DIR"