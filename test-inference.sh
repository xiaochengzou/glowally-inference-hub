#!/bin/bash

# Configuration
SERVICE_NAME="vllm-lb-service"
LORA_MODEL_NAME="sql-expert"
CREATIVE_MODEL_NAME="creative"
BASE_MODEL_NAME="Qwen/Qwen2.5-7B-Instruct"
LOAD_DURATION=300  # 5 minutes in seconds
LOAD_INTERVAL=3    # seconds between requests during load test

echo "🔍 [1/8] Detecting LoadBalancer IP..."
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

echo -e "\n📡 [2/8] Verifying available models..."
curl -s "$ENDPOINT/v1/models" | jq .

echo -e "\n🤖 [3/8] Test: Base Model General Knowledge..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$BASE_MODEL_NAME\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What are the three laws of robotics?\"}],
    \"max_tokens\": 100
  }" | jq .choices[0].message.content

echo -e "\n🎯 [4/8] Test: LoRA Adapter Simple SQL..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Table 'orders' has columns: id, amount, status. Write a query for completed orders > 100.\"}
    ],
    \"max_tokens\": 100
  }" | jq .choices[0].message.content

echo -e "\n🧠 [5/8] Test: LoRA Adapter Complex Schema..."
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

echo -e "\n✍️  [6/8] Test: Creative Adapter — Short Scene..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$CREATIVE_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Write a short cyberpunk opening paragraph set in a rain-soaked neon city.\"}
    ],
    \"max_tokens\": 150,
    \"temperature\": 0.8
  }" | jq .choices[0].message.content

echo -e "\n🌆 [7/8] Test: Creative Adapter — Character Description..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$CREATIVE_MODEL_NAME\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a cyberpunk fiction writer with a vivid, noir style.\"},
      {\"role\": \"user\", \"content\": \"Describe a street hacker named Void who sells stolen corporate secrets in the undercity.\"}
    ],
    \"max_tokens\": 200,
    \"temperature\": 0.9
  }" | jq .choices[0].message.content

echo -e "\n🌊 [8/8] Test: Streaming Output (LoRA)..."
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$LORA_MODEL_NAME\",
    \"messages\": [{\"role\": \"user\", \"content\": \"List all SQL constraints and explain them briefly.\"}],
    \"stream\": true,
    \"max_tokens\": 150
  }" | head -n 20

echo -e "\n✅ Smoke tests completed."

# ── 5-Minute Load Test ────────────────────────────────────────────────────────
echo -e "\n🔥 Starting 5-minute load test..."
echo "   Duration: ${LOAD_DURATION}s | Interval: ${LOAD_INTERVAL}s between requests"
echo "   Watch your Grafana dashboard to see metrics light up!"
echo "   Press Ctrl+C to stop early."
echo ""

# Pool of varied SQL prompts to simulate realistic traffic
SQL_PROMPTS=(
  "Table 'users' has columns: id, name, email, created_at. Write a query to find all users created in the last 30 days."
  "Schema: products(id, name, price, stock). Write a query to find all products with stock less than 10."
  "Table 'employees' has columns: id, name, department, salary. Find the average salary per department."
  "Schema: orders(id, customer_id, total, status), customers(id, name, email). Find all customers who placed orders over 500 dollars."
  "Table 'logs' has columns: id, user_id, action, timestamp. Count the number of actions per user in the last 7 days."
  "Schema: students(id, name), courses(id, title), enrollments(student_id, course_id, grade). Find students with GPA above 3.5."
  "Table 'inventory' has columns: id, product_name, quantity, warehouse_id. Find warehouses with total quantity above 1000."
  "Schema: transactions(id, account_id, amount, type, date). Calculate total deposits and withdrawals per account."
  "Table 'reviews' has columns: id, product_id, rating, comment. Find products with average rating above 4."
  "Schema: flights(id, origin, destination, departure, arrival, seats_available). Find all flights from SFO with available seats."
)

BASE_PROMPTS=(
  "Explain what a database index is and when to use one."
  "What is the difference between INNER JOIN and LEFT JOIN in SQL?"
  "Explain database normalization and its benefits."
  "What are ACID properties in database transactions?"
  "Explain the difference between a primary key and a foreign key."
)

CREATIVE_PROMPTS=(
  "Write a two-sentence cyberpunk scene set in a flooded megacity."
  "Describe the neon-lit marketplace where black-market AIs are sold."
  "Write a terse internal monologue of a mercenary waiting for a heist."
  "Describe the moment a hacker breaches a corporate mainframe."
  "Write a cyberpunk haiku about a dying android."
)

START_TIME=$(date +%s)
END_TIME=$((START_TIME + LOAD_DURATION))
REQUEST_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

while [ $(date +%s) -lt $END_TIME ]; do
  ELAPSED=$(($(date +%s) - START_TIME))
  REMAINING=$((END_TIME - $(date +%s)))

  # Rotate across base, sql-expert, and creative adapters
  TURN=$((REQUEST_COUNT % 4))
  if [ $TURN -eq 0 ]; then
    PROMPT_IDX=$((REQUEST_COUNT % ${#BASE_PROMPTS[@]}))
    PROMPT="${BASE_PROMPTS[$PROMPT_IDX]}"
    MODEL="$BASE_MODEL_NAME"
    MODEL_LABEL="base"
  elif [ $TURN -eq 1 ] || [ $TURN -eq 2 ]; then
    PROMPT_IDX=$((REQUEST_COUNT % ${#SQL_PROMPTS[@]}))
    PROMPT="${SQL_PROMPTS[$PROMPT_IDX]}"
    MODEL="$LORA_MODEL_NAME"
    MODEL_LABEL="sql"
  else
    PROMPT_IDX=$((REQUEST_COUNT % ${#CREATIVE_PROMPTS[@]}))
    PROMPT="${CREATIVE_PROMPTS[$PROMPT_IDX]}"
    MODEL="$CREATIVE_MODEL_NAME"
    MODEL_LABEL="creative"
  fi

  REQUEST_COUNT=$((REQUEST_COUNT + 1))

  # Send request and capture HTTP status
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
      \"max_tokens\": 150,
      \"temperature\": 0.7
    }")

  if [ "$HTTP_STATUS" == "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    STATUS_ICON="✅"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    STATUS_ICON="❌"
  fi

  printf "\r⏱  %3ds elapsed | %3ds remaining | req #%d | %s [%s] HTTP %s   " \
    "$ELAPSED" "$REMAINING" "$REQUEST_COUNT" "$STATUS_ICON" "$MODEL_LABEL" "$HTTP_STATUS"

  sleep $LOAD_INTERVAL
done

echo -e "\n\n📊 Load Test Summary"
echo "════════════════════════════════"
echo "  Duration:      ${LOAD_DURATION}s"
echo "  Total requests: $REQUEST_COUNT"
echo "  Successful:     $SUCCESS_COUNT"
echo "  Failed:         $FAIL_COUNT"
echo "  Success rate:   $(( SUCCESS_COUNT * 100 / REQUEST_COUNT ))%"
echo "════════════════════════════════"
echo ""
echo "✅ Load test complete. Check your Grafana dashboards for:"
echo "   • vLLM dashboard: tokens/sec, TTFT, request throughput"
echo "   • GPU Hardware dashboard: SM active ratio, tensor core usage, power draw"
echo "   • Adapter routing: sql-expert vs creative requests split 2:1 vs base"