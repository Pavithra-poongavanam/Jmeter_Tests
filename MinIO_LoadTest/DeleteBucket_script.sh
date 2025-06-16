#!/bin/bash

# ---------------------- CONFIGURATION ----------------------
MINIO_HOST="172.16.23.8"                      # MinIO server IP
MINIO_USER="pavithra"                         # SSH username
JMX_PATH="/home/pavithra/jmeter/bin/MinIOConsole/DeleteBucket.jmx"
JMETER_BIN="/home/pavithra/jmeter/bin/jmeter"
RESULT_DIR="minio_test_$(date +%Y%m%d_%H%M%S)"
OUTPUT_CSV="$RESULT_DIR/results.jtl"
# -----------------------------------------------------------

mkdir -p "$RESULT_DIR"

echo "▶️ Starting sar monitoring on MinIO server ($MINIO_HOST)..."
ssh "$MINIO_USER@$MINIO_HOST" "nohup sar -u 1 > /tmp/cpu_usage.log 2>&1 &"
ssh "$MINIO_USER@$MINIO_HOST" "nohup sar -r 1 > /tmp/mem_usage.log 2>&1 &"

echo "🚀 Running JMeter test..."
"$JMETER_BIN" -n -t "$JMX_PATH" -l "$OUTPUT_CSV" -Jjmeter.save.saveservice.output_format=csv

echo "⏹️ Stopping sar on MinIO server..."
ssh "$MINIO_USER@$MINIO_HOST" "pkill sar"

echo "📥 Copying CPU and Memory logs from MinIO server..."
scp "$MINIO_USER@$MINIO_HOST:/tmp/cpu_usage.log" "$RESULT_DIR/"
scp "$MINIO_USER@$MINIO_HOST:/tmp/mem_usage.log" "$RESULT_DIR/"

echo "📊 Extracting JMeter and system metrics..."

# ------------------ Extract Metrics ------------------
JTL_FILE="$OUTPUT_CSV"
CPU_LOG="$RESULT_DIR/cpu_usage.log"
MEM_LOG="$RESULT_DIR/mem_usage.log"
SUMMARY_FILE="$RESULT_DIR/summary.txt"

# ----- JMeter Metrics -----
total_samples=$(tail -n +2 "$JTL_FILE" | wc -l)
avg_latency=$(awk -F',' 'NR>1 {sum += $2} END {if (NR>1) print int(sum/(NR-1)); else print 0}' "$JTL_FILE")
min_latency=$(awk -F',' 'NR>1 {if (min=="" || $2<min) min=$2} END {print min}' "$JTL_FILE")
max_latency=$(awk -F',' 'NR>1 {if ($2>max) max=$2} END {print max}' "$JTL_FILE")
error_count=$(awk -F',' 'NR>1 && $8=="false" {count++} END {print count+0}' "$JTL_FILE")
error_percentage=$(awk -v total=$total_samples -v errors=$error_count 'BEGIN {if (total > 0) printf "%.2f", (errors / total) * 100; else print "0.00"}')
start_time=$(awk -F',' 'NR==2 {print $1}' "$JTL_FILE")
end_time=$(awk -F',' 'END {print $1}' "$JTL_FILE")
duration_sec=$(( (end_time - start_time) / 1000 ))
if [[ $duration_sec -eq 0 ]]; then duration_sec=1; fi
throughput=$(awk -v t=$duration_sec -v s=$total_samples 'BEGIN {printf "%.2f", s/t}')

# ----- System Metrics -----
cpu_avg=$(awk '/^[0-9]/ {sum += 100 - $(NF); count++} END {if (count > 0) printf "%.2f", sum/count; else print "0.00"}' "$CPU_LOG")
mem_avg=$(awk '
  /^[0-9]/ && $2+0 > 0 && $4+0 > 0 {
    sum += ($4 / $2) * 100;
    count++
  }
  END {
    if (count > 0) printf "%.2f", sum / count;
    else print "0.00"
  }
' "$MEM_LOG")


# ------------------ Write Summary ------------------
{
  echo "========== JMeter Test Summary =========="
  echo "Total Samples: $total_samples"
  echo "Avg Latency (ms): $avg_latency"
  echo "Min Latency (ms): $min_latency"
  echo "Max Latency (ms): $max_latency"
  echo "Error Count: $error_count"
  echo "Error Percentage: $error_percentage %"
  echo "Test Duration: $duration_sec seconds"
  echo "Throughput: $throughput req/sec"
  echo ""
  echo "========== CPU and Memory Usage =========="
  echo "Average CPU Usage (%): $cpu_avg"
  echo "Average Memory Usage (%): $mem_avg"
} > "$SUMMARY_FILE"

echo "✅ Done! All data and summary saved in: $RESULT_DIR"
