#!/bin/bash

if  [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	echo "DepParse - YUM/DNF Dependency Error Analyzer"
	echo "============================================="
	echo ""
	echo "Usage: ./yumlooper.sh [OPTIONS]"
	echo ""
	echo "This tool analyzes yum/dnf dependency errors and provides fix recommendations."
	echo ""
	echo "Steps:"
	echo "  1. Copy your yum/dnf error output to a file named 'yumlog.txt'"
	echo "  2. Run: ./yumlooper.sh"
	echo "  3. View the fix command on screen or share depparse_analysis.log"
	echo ""
	echo "Options:"
	echo "  -h, --help       Show this help message"
	echo "  -v, --verbose    Future use (reserved for debugging)"
	echo "  -n, --no-repo    Skip repository queries (analyze log only)"
	echo ""
	echo "Output:"
	echo "  - Screen: Quick summary with recommended fix command"
	echo "  - File: depparse_analysis.log (comprehensive analysis)"
	echo ""
	echo "Note:"
	echo "  This tool runs 'yum whatprovides' and 'yum list' commands to query"
	echo "  repositories. These are read-only operations that do not modify your system."
	echo "  Use -n/--no-repo to skip repository queries if needed."
	echo ""
	exit 0
fi

VERBOSE=0
OFFLINE=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -n|--no-repo)
            OFFLINE=1
            shift
            ;;
        *)
            ;;
    esac
done

echo "================================"
echo "DepParse - Dependency Analyzer"
echo "================================"

if [ "$OFFLINE" -eq 1 ]; then
    echo "Running in NO-REPO mode (skipping repository queries)"
    echo ""
fi

echo "Step 1: Parsing yumlog.txt..."

# Check if input file exists
if [ ! -f "yumlog.txt" ]; then
    echo ""
    echo "ERROR: yumlog.txt not found!"
    echo ""
    echo "Please create a file named 'yumlog.txt' with your yum/dnf error output."
    echo "Example: yum update 2>&1 | tee yumlog.txt"
    echo ""
    exit 1
fi

# Check if input file is empty
if [ ! -s "yumlog.txt" ]; then
    echo ""
    echo "ERROR: yumlog.txt is empty!"
    echo ""
    echo "Please ensure the file contains yum/dnf error output."
    echo ""
    exit 1
fi

# Single comprehensive log file
ANALYSIS_LOG="depparse_analysis.log"
:>| "$ANALYSIS_LOG"

# Temporary working files (will be cleaned up)
TEMP_FAILPKG=$(mktemp)
TEMP_DEPD=$(mktemp)

PROBLEM_NUM=0

# Write header to log file
cat >> "$ANALYSIS_LOG" << EOF
================================================================================
                    DEPENDENCY ANALYSIS REPORT
================================================================================
Generated: $(date)
Source: yumlog.txt

EOF

# Parse the log and build structured data
echo "" >> "$ANALYSIS_LOG"
echo "DETAILED DEPENDENCY CHAINS:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

while read line; do
   # Track problem numbers for better organization
   if [[ "$line" == *"Problem"* ]]; then
       PROBLEM_NUM=$(awk '/Problem/{print $2}' <<< "$line" | tr -d ':')
       if [[ -n "$PROBLEM_NUM" ]]; then
           echo "" >> "$ANALYSIS_LOG"
           echo "=== Problem $PROBLEM_NUM ===" >> "$ANALYSIS_LOG"
       fi
   fi

   # Parse "problem with installed package" lines
   if [[ "$line" == *"problem with installed package"* ]]; then
       INSTALLED_PKG=$(awk '/problem with installed package/{print $NF}' <<< $line)
       echo "$INSTALLED_PKG" >> "$TEMP_FAILPKG"
       echo "Installed: $INSTALLED_PKG" >> "$ANALYSIS_LOG"
   fi

   # Parse "package requires" dependencies to build dependency chains
   if [[ "$line" == *"package"* ]] && [[ "$line" == *"requires"* ]]; then
       awk '/package.*requires/{
           for(i=1;i<=NF;i++) {
               if($i=="package") pkg=$(i+1);
               if($i=="requires") {
                   req=$(i+1);
                   for(j=i+2;j<=NF;j++) {
                       if($j=="but") break;
                       req=req" "$j;
                   }
                   print "  |-- " pkg " requires: " req;
               }
           }
       }' <<< "$line" >> "$ANALYSIS_LOG"
   fi

   # Parse "nothing provides" errors - these are the root causes
   if [[ "$line" == *"nothing provides"* ]]; then
       # Extract the missing dependency
       awk '{print $4}' <<< "$line" >> "$TEMP_DEPD"

       # Get the package that needs this dependency
       awk '/nothing provides/{print $NF}' <<< "$line" >> "$TEMP_FAILPKG"
       echo '--' >> "$TEMP_FAILPKG"

       # Store full dependency info in a clear format
       awk '/nothing provides/{
           for(i=1;i<=NF;i++) {
               if($i=="provides") {
                   missing="";
                   for(j=i+1;j<=NF;j++) {
                       if($j=="needed") break;
                       missing=missing" "$j;
                   }
                   sub(/^ /, "", missing);
               }
               if($i=="needed" && $(i+1)=="by") {
                   needed_by=$NF;
               }
           }
           print "  \\-- MISSING: " missing;
           print "      (needed by: " needed_by ")";
       }' <<< "$line" >> "$ANALYSIS_LOG"
   fi
done < yumlog.txt

# Skip the failed packages summary - it's redundant with detailed chains above

# Add missing dependencies section to log
echo "" >> "$ANALYSIS_LOG"
echo "" >> "$ANALYSIS_LOG"
echo "ROOT CAUSE - MISSING DEPENDENCIES:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

if [ -s "$TEMP_DEPD" ]; then
    cat "$TEMP_DEPD" | sort -u >> "$ANALYSIS_LOG"

    # Only query repositories if not in offline mode
    if [ "$OFFLINE" -eq 0 ]; then
        echo "" >> "$ANALYSIS_LOG"
        echo "" >> "$ANALYSIS_LOG"
        echo "REPOSITORY ANALYSIS:" >> "$ANALYSIS_LOG"
        echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

        # Create temporary files to store analysis
        TEMP_PROVIDES=$(mktemp)
        TEMP_WHATPROVIDES=$(mktemp)
        TEMP_PACKAGES=$(mktemp)

        # Run whatprovides for each missing dependency and capture detailed output
        DEP_COUNT=$(cat "$TEMP_DEPD" | sort -u | wc -l)
        echo ""
        echo "Step 2: Querying repositories for $DEP_COUNT missing dependencies..."
        echo "        (This may take a moment - querying yum repositories)"
        CURRENT_DEP=0
        while read dep; do
            CURRENT_DEP=$((CURRENT_DEP + 1))
            echo "  [$CURRENT_DEP/$DEP_COUNT] $dep"
            # Don't clutter the log with "Analyzing:" lines - show progress only on stdout

            if ! yum whatprovides "$dep" > "$TEMP_WHATPROVIDES" 2>&1; then
                echo "Warning: Query failed for dependency: $dep" >> "$ANALYSIS_LOG"
            fi

            # Extract package names for yum list
            egrep -v "^Repo|^Matched|^Provide|^Filename|^Last" "$TEMP_WHATPROVIDES" | \
                awk -F. '/.el8/{print $1}' | sed 's:-[0-9].*::' >> "$TEMP_PACKAGES"
        done < <(cat "$TEMP_DEPD" | sort -u)

        if [ -s "$TEMP_PACKAGES" ]; then
            echo "" >> "$ANALYSIS_LOG"
            echo "Available packages providing missing dependencies:" >> "$ANALYSIS_LOG"
            echo ""
            echo "Step 3: Checking package availability in repositories..."
            if ! yum list $(cat "$TEMP_PACKAGES" | sort -u) 2>&1 | tee /tmp/yumlist_output.txt >> "$ANALYSIS_LOG"; then
                echo "  Warning: Some packages may not be available" >> "$ANALYSIS_LOG"
            fi

        echo "" >> "$ANALYSIS_LOG"
        echo "" >> "$ANALYSIS_LOG"
        echo "================================================================================" >> "$ANALYSIS_LOG"
        echo "                         RECOMMENDED FIXES" >> "$ANALYSIS_LOG"
        echo "================================================================================" >> "$ANALYSIS_LOG"

        # Analyze the yum list output to provide specific recommendations
        if [ -f /tmp/yumlist_output.txt ]; then
            echo "" >> "$ANALYSIS_LOG"
            echo "To fix the dependency issues, install/update these packages:" >> "$ANALYSIS_LOG"
            echo "" >> "$ANALYSIS_LOG"

            # Extract available packages (not installed ones)
            awk '/^Available Packages/,0' /tmp/yumlist_output.txt | \
                grep -E "\.el8" | \
                awk '{printf "  • %s-%s (from %s)\n", $1, $2, $3}' >> "$ANALYSIS_LOG"

            echo "" >> "$ANALYSIS_LOG"
            echo "Installation commands:" >> "$ANALYSIS_LOG"
            echo "---------------------" >> "$ANALYSIS_LOG"

            # Generate install command with available versions
            INSTALL_PKGS=$(awk '/^Available Packages/,0' /tmp/yumlist_output.txt | \
                grep -E "\.el8" | \
                awk '{print $1}' | \
                sort -u | tr '\n' ' ')

            if [ -n "$INSTALL_PKGS" ]; then
                echo "yum install $INSTALL_PKGS" >> "$ANALYSIS_LOG"
                echo "" >> "$ANALYSIS_LOG"
                echo "# Or to update:" >> "$ANALYSIS_LOG"
                echo "yum update $INSTALL_PKGS" >> "$ANALYSIS_LOG"

                # Store for stdout display
                FIX_COMMAND="yum install $INSTALL_PKGS"
            else
                echo "Note: All required packages appear to be already installed." >> "$ANALYSIS_LOG"
                echo "The issue might be version mismatches. Try:" >> "$ANALYSIS_LOG"
                echo "" >> "$ANALYSIS_LOG"

                # Get the base package names from temp failpkg
                FAILED_PKGS=$(cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | \
                    awk '{print $1}' | sed 's/-[0-9].*$//' | sort -u | tr '\n' ' ')

                if [ -n "$FAILED_PKGS" ]; then
                    echo "yum update $FAILED_PKGS" >> "$ANALYSIS_LOG"
                    FIX_COMMAND="yum update $FAILED_PKGS"
                fi
            fi

            rm -f /tmp/yumlist_output.txt
        fi
        else
            echo "WARNING: No packages found that provide the missing dependencies!" >> "$ANALYSIS_LOG"
            echo "This could mean:" >> "$ANALYSIS_LOG"
            echo "  1. The required packages are not available in your enabled repositories" >> "$ANALYSIS_LOG"
            echo "  2. You may need to enable additional repositories" >> "$ANALYSIS_LOG"
            echo "  3. The dependency versions are not available for your RHEL version" >> "$ANALYSIS_LOG"
        fi

        rm -f "$TEMP_PROVIDES" "$TEMP_WHATPROVIDES" "$TEMP_PACKAGES"
    else
        echo "" >> "$ANALYSIS_LOG"
        echo "" >> "$ANALYSIS_LOG"
        echo "REPOSITORY ANALYSIS: SKIPPED (no-repo mode)" >> "$ANALYSIS_LOG"
        echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
        echo "Repository queries were skipped. Run without -n/--no-repo to get package recommendations." >> "$ANALYSIS_LOG"
    fi
else
    echo "No dependency issues found" >> "$ANALYSIS_LOG"
fi

# Display summary to stdout
echo ""
echo "================================"
echo "ANALYSIS COMPLETE"
echo "================================"

# Check if any problems were found
PROBLEMS_FOUND=0
PROBLEM_COUNT=0
if [ -s "$TEMP_DEPD" ]; then
    PROBLEMS_FOUND=1
fi

# Count problems from log file
if [ -f "$ANALYSIS_LOG" ]; then
    PROBLEM_COUNT=$(grep -c "^=== Problem" "$ANALYSIS_LOG" 2>/dev/null || echo "0")
fi

if [ "$PROBLEMS_FOUND" -eq 1 ]; then
    echo "Found $PROBLEM_COUNT dependency problem(s)"
    echo ""

    # Count affected packages
    AFFECTED_COUNT=$(cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | sort -u | wc -l)

    # Show affected packages
    echo "Affected Packages ($AFFECTED_COUNT):"
    echo "--------------------"
    cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | awk '{print $1}' | sed 's/-[0-9].*$//' | sort -u | \
        awk '{printf "  • %s\n", $0}'
    echo ""

    # Show missing dependencies
    DEP_COUNT=$(cat "$TEMP_DEPD" | sort -u | wc -l)
    echo "Missing Dependencies ($DEP_COUNT):"
    echo "--------------------"
    cat "$TEMP_DEPD" | sort -u | head -10 | awk '{printf "  • %s\n", $0}'
    if [ "$DEP_COUNT" -gt 10 ]; then
        echo "  ... and $((DEP_COUNT - 10)) more (see log file)"
    fi
    echo ""

    # Show next steps based on whether fix is available
    if [ -n "$FIX_COMMAND" ]; then
        echo "Recommended fix command is available in the analysis log."
    else
        echo "No automatic fix available. Review the analysis log for details."
    fi
else
    echo "No dependency problems found in yumlog.txt"
    echo ""
    echo "The log file may not contain dependency errors, or they are already resolved."
fi

echo ""
echo "================================"
echo "Full analysis saved to: $ANALYSIS_LOG"
echo "================================"
echo ""

# Clean up all temporary files (ensure cleanup happens regardless of errors)
rm -f "$TEMP_FAILPKG" "$TEMP_DEPD" 2>/dev/null
rm -f /tmp/yumlist_output.txt 2>/dev/null

# Clean up other temp files if they exist
if [ -n "$TEMP_PROVIDES" ]; then
    rm -f "$TEMP_PROVIDES" 2>/dev/null
fi
if [ -n "$TEMP_WHATPROVIDES" ]; then
    rm -f "$TEMP_WHATPROVIDES" 2>/dev/null
fi
if [ -n "$TEMP_PACKAGES" ]; then
    rm -f "$TEMP_PACKAGES" 2>/dev/null
fi
