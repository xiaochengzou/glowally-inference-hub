#!/bin/bash

# Configuration
SERVICE_NAME="vllm-lb-service"
LORA_MODEL_NAME="sql-expert"
BASE_MODEL_NAME="Qwen/Qwen2.5-7B-Instruct"

echo "🔍 [1/4] Detecting LoadBalancer IP..."
EXTERNAL_IP=$(kubectl get svc $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Handle cases where hostname is used instead of IP (e.g., on AWS or some local clusters)
if [ -z "$EXTERNAL_IP" ]; then
    EXTERNAL_IP=$(kubectl get svc $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

if [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" == "<pending>" ]; then
    echo "⚠️  External IP is still pending or not found."
    echo "💡 Using 'localhost:8000' (Assumes port-forward is running: kubectl port-forward svc/$SERVICE_NAME 8000:80)"
    ENDPOINT="http://localhost:8000"
else
    echo "✅ Found External IP: $EXTERNAL_IP"
    ENDPOINT="http://$EXTERNAL_IP"
fi

echo -e "\n📡 [2/4] Verifying available models at $ENDPOINT/v1/models..."
curl -s "$ENDPOINT/v1/models" | jq .

echo -e "\n🤖 [3/4] Testing BASE MODEL ($BASE_MODEL_NAME)..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$BASE_MODEL_NAME\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello, what model are you?\"}],
    \"max_tokens\": 50
  }" | jq .choices[0].message.content

echo -e "\n🎯 [4/4] Testing LORA ADAPTER ($LORA_MODEL_NAME)..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a SQL expert.\"},
      {\"role\": \"user\", \"content\": \"Write a SQL query to find all users who signed up in the last 30 days.\"}
    ],
    \"max_tokens\": 100
  }" | jq .choices[0].message.content

echo -e "\n✅ Tests completed."
