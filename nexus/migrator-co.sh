#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================

# SOURCE: Sonatype Nexus
NEXUS_BASE_URL="http://localhost:8081"
NEXUS_REPO_NAME="c4e"
NEXUS_USER="admin"
NEXUS_PASS="Admin123"

# TARGET: JFrog Artifactory OSS
ART_BASE_URL="http://65.109.137.18:8082/artifactory"
ART_REPO_NAME="libs-release-local"
ART_USER="admin"
ART_PASS="Admin123"

# TEMP DIRECTORY
WORK_DIR="./migration_temp"

# ==========================================
# MIGRATION LOGIC
# ==========================================

# 0. Clean Environment
unset http_proxy
unset https_proxy

# 1. Check for jq
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' is not installed. Please install it (e.g., sudo apt install jq)."
    exit 1
fi

mkdir -p "$WORK_DIR"

echo "=========================================="
echo " STARTING MIGRATION: $NEXUS_REPO_NAME -> $ART_REPO_NAME"
echo "=========================================="
echo "[INFO] Source: $NEXUS_BASE_URL"

CONTINUATION_TOKEN=""
TEMP_RESPONSE_FILE=$(mktemp)

while true; do
    # Construct API URL
    API_URL="${NEXUS_BASE_URL}/service/rest/v1/assets?repository=${NEXUS_REPO_NAME}"
    if [ ! -z "$CONTINUATION_TOKEN" ] && [ "$CONTINUATION_TOKEN" != "null" ]; then
        API_URL="${API_URL}&continuationToken=${CONTINUATION_TOKEN}"
    fi

    echo "[INFO] Fetching asset list from Nexus..."
    
    # Fetch JSON response using temp file strategy to avoid curl formatting issues
    HTTP_CODE=$(curl -s -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" -u "$NEXUS_USER:$NEXUS_PASS" "$API_URL")
    
    # Analyze Nexus Response
    if [[ "$HTTP_CODE" != "200" ]]; then
        echo "---------------------------------------------------"
        echo "[CRITICAL ERROR] Nexus API Failed (HTTP $HTTP_CODE)."
        echo "---------------------------------------------------"
        echo "Response Body:"
        cat "$TEMP_RESPONSE_FILE"
        echo ""
        echo "---------------------------------------------------"
        rm "$TEMP_RESPONSE_FILE"
        exit 1
    fi

    # Extract Items
    # We read from the temp file to ensure clean JSON parsing
    cat "$TEMP_RESPONSE_FILE" | jq -r '.items[] | "\(.downloadUrl)\t\(.path)"' | while IFS=$'\t' read -r DOWNLOAD_URL ARTIFACT_PATH; do
        
        # Clean path
        CLEAN_PATH=${ARTIFACT_PATH#/}
        LOCAL_FILE="$WORK_DIR/$(basename "$CLEAN_PATH")"
        
        # A. DOWNLOAD
        curl -s -u "$NEXUS_USER:$NEXUS_PASS" -o "$LOCAL_FILE" "$DOWNLOAD_URL"
        
        if [ ! -f "$LOCAL_FILE" ]; then
            echo "[WARN] Failed to download $CLEAN_PATH. Skipping."
            continue
        fi

        # B. CALCULATE CHECKSUM
        CHECKSUM=$(sha1sum "$LOCAL_FILE" | awk '{print $1}')

        # C. UPLOAD TO ARTIFACTORY
        TARGET_URL="${ART_BASE_URL}/${ART_REPO_NAME}/${CLEAN_PATH}"
        echo "[UPLOAD] Sending $CLEAN_PATH..."
        
        HTTP_CODE_ART=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "$ART_USER:$ART_PASS" \
            -X PUT \
            -H "X-Checksum-Sha1: $CHECKSUM" \
            -T "$LOCAL_FILE" \
            "$TARGET_URL")

        if [[ "$HTTP_CODE_ART" == "201" || "$HTTP_CODE_ART" == "200" ]]; then
            echo "    [OK] Success"
        else
            echo "    [FAIL] HTTP $HTTP_CODE_ART"
        fi

        # D. CLEANUP
        rm "$LOCAL_FILE"

    done

    # Check for next page
    CONTINUATION_TOKEN=$(cat "$TEMP_RESPONSE_FILE" | jq -r '.continuationToken')
    
    if [ "$CONTINUATION_TOKEN" == "null" ] || [ -z "$CONTINUATION_TOKEN" ]; then
        echo "=========================================="
        echo " MIGRATION COMPLETE."
        echo "=========================================="
        break
    fi
done

rm "$TEMP_RESPONSE_FILE"
rm -rf "$WORK_DIR"