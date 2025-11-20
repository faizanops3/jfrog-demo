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
ART_REPO_NAME="libs-release-local"
ART_USER="admin"
ART_PASS="Admin123"  # Updated based on your last message

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

mkdir -p "$WORK_DIR"

echo "=========================================="
echo " STARTING MIGRATION: $NEXUS_REPO_NAME -> $ART_REPO_NAME"
echo "=========================================="
echo "[INFO] Skipping pre-flight check. Attempting direct migration..."

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

    # Extract Items
    echo "$RESPONSE" | jq -r '.items[] | "\(.downloadUrl)\t\(.path)"' | while IFS=$'\t' read -r DOWNLOAD_URL ARTIFACT_PATH; do
        
        # Clean path
        CLEAN_PATH=${ARTIFACT_PATH#/}
        LOCAL_FILE="$WORK_DIR/$(basename "$CLEAN_PATH")"
        
        # A. DOWNLOAD
        curl -s -u "$NEXUS_USER:$NEXUS_PASS" -o "$LOCAL_FILE" "$DOWNLOAD_URL"
        
        if [ ! -f "$LOCAL_FILE" ]; then
            echo "[ERROR] Failed to download $CLEAN_PATH"
            continue
        fi

        # B. CALCULATE CHECKSUM
        CHECKSUM=$(sha1sum "$LOCAL_FILE" | awk '{print $1}')

        # C. UPLOAD TO ARTIFACTORY
        TARGET_URL="${ART_BASE_URL}/${ART_REPO_NAME}/${CLEAN_PATH}"
        echo "[UPLOAD] uploading to: $TARGET_URL"
        
        # Verbose output for debugging
        HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
            -u "$ART_USER:$ART_PASS" \
            -X PUT \
            -H "X-Checksum-Sha1: $CHECKSUM" \
            -T "$LOCAL_FILE" \
            "$TARGET_URL")

        HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
        RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

        if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
            echo "[SUCCESS] Uploaded $CLEAN_PATH"
        else
            echo "[ERROR] Upload failed (HTTP $HTTP_CODE)"
            echo "        Response: $RESPONSE_BODY"
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