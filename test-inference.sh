#!/bin/bash

# Configuration
SERVICE_NAME="vllm-lb-service"
LORA_MODEL_NAME="sql-expert"
BASE_MODEL_NAME="Qwen/Qwen2.5-7B-Instruct"

echo "🔍 [1/6] Detecting LoadBalancer IP..."
EXTERNAL_IP=$(kubectl get svc $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Handle cases where hostname is used instead of IP
if [ -z "$EXTERNAL_IP" ]; then
    EXTERNAL_IP=$(kubectl get svc $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

if [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" == "<pending>" ]; then
    echo "❌ ERROR: External IP is not available yet (currently: $EXTERNAL_IP)."
    echo "Please wait a few minutes for GCP to provision the LoadBalancer or check status with:"
    echo "kubectl get svc $SERVICE_NAME"
    exit 1
fi

echo "✅ Found External IP: $EXTERNAL_IP"
ENDPOINT="http://$EXTERNAL_IP"

echo -e "\n📡 [2/6] Verifying available models..."
curl -s "$ENDPOINT/v1/models" | jq .

echo -e "\n🤖 [3/6] Test: Base Model General Knowledge..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$BASE_MODEL_NAME\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What are the three laws of robotics?\"}],
    \"max_tokens\": 100
  }" | jq .choices[0].message.content

echo -e "\n🎯 [4/6] Test: LoRA Adapter Simple SQL..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Table 'orders' has columns: id, amount, status. Write a query for completed orders > 100.\"}
    ],
    \"max_tokens\": 100
  }" | jq .choices[0].message.content

echo -e "\n🧠 [5/6] Test: LoRA Adapter Complex Schema..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a SQL expert. Use JOINs where appropriate.\"},
      {\"role\": \"user\", \"content\": \"Schema: users(id, name), posts(id, author_id, title, views). Task: Find the names of authors who have posts with more than 1000 views.\"}
    ],
    \"temperature\": 0
  }" | jq .choices[0].message.content

echo -e "\n🌊 [6/6] Test: Streaming Output (LoRA)..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [{\"role\": \"user\", \"content\": \"List all SQL constraints and explain them briefly.\"}],
    \"stream\": true,
    \"max_tokens\": 150
  }" | head -n 20

echo -e "\n✅ All tests completed."
