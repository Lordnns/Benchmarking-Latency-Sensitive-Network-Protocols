#!/bin/bash

# ==============================================================================
# Results Processor
# ==============================================================================
# Finds all .csv benchmark results and generates corresponding .json statistics
# using the ./target/release/stats binary.
# ==============================================================================

RESULTS_DIR="benchmark_results"
STATS_BIN="./target/release/stats"

# Check if stats binary exists
if [ ! -f "$STATS_BIN" ]; then
    echo "Stats binary not found at $STATS_BIN. Please run 'cargo build --release --bin stats'."
    exit 1
fi

# Check if results directory exists
if [ ! -d "$RESULTS_DIR" ]; then
    echo "Results directory '$RESULTS_DIR' not found."
    exit 1
fi

echo "Processing results in '$RESULTS_DIR'..."

# Find all CSV files recursively
find "$RESULTS_DIR" -type f -name "*.csv" | while read -r CSV_FILE; do
    # Generate JSON filename (e.g., udp.csv -> udp.json)
    JSON_FILE="${CSV_FILE%.csv}.json"

    echo "  Processing: $CSV_FILE -> $JSON_FILE"

    # Run the stats tool and redirect stdout to the JSON file
    if $STATS_BIN "$CSV_FILE" > "$JSON_FILE"; then
        # Optional: Check if the file is empty (if stats failed silently)
        if [ ! -s "$JSON_FILE" ]; then
             echo "    Warning: Output JSON is empty."
        fi
    else
        echo "    Error processing $CSV_FILE"
    fi
done

echo "Done. JSON files generated."