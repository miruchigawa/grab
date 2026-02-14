#!/bin/bash
# Regression tests for the grab search tool.

# Verify the tool is built before running tests.
make -s

# Console styling for test results.
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

run_test() {
    name="$1"
    pattern="$2"
    file="$3"
    expected_matches="$4"

    echo "Running test: $name"
    
    # Run the tool and capture output.
    output=$(./grab "$pattern" "$file")
    status=$?
    
    if [ $status -ne 0 ]; then
        echo -e "${RED}FAIL${NC}: grab exited with status $status"
        fail=$((fail+1))
        return
    fi
    
    # Verify match count matches expectation.
    matches=$(echo "$output" | grep -c "$pattern")
    
    if [ "$matches" -eq "$expected_matches" ]; then
        echo -e "${GREEN}PASS${NC}"
        pass=$((pass+1))
    else
        echo -e "${RED}FAIL${NC}: Expected $expected_matches matches, got $matches"
        fail=$((fail+1))
    fi
}

# Setup temporary test data.
echo "apple banana cherry" > test_file.txt
echo "banana date elderberry" >> test_file.txt
echo "fig grape honeydew" >> test_file.txt
echo "apple ice cream" >> test_file.txt

# Execute test cases.
run_test "Simple match 'apple'" "apple" "test_file.txt" 2
run_test "No match 'zebra'" "zebra" "test_file.txt" 0
run_test "Long pattern match" "apple banana cherry" "test_file.txt" 1

# Cleanup test environment.
rm test_file.txt

echo "-----------------------------------"
echo "Tests passed: $pass"
echo "Tests failed: $fail"

if [ $fail -gt 0 ]; then
    exit 1
fi
exit 0
