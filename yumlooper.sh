#!/bin/bash

if  [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	echo "DepParse - YUM/DNF Dependency Error Analyzer"
	echo "============================================="
	echo ""
	echo "Usage: ./yumlooper.sh [OPTIONS]"
	echo ""
	echo "This tool analyzes yum/dnf dependency errors and provides troubleshooting guidance."
	echo ""
	echo "Steps:"
	echo "  1. Get the dependency error from customer: dnf update 2>&1 | tee yumlog.txt"
	echo "  2. Run: ./yumlooper.sh"
	echo "  3. Script analyzes the error and shows commands to run for diagnosis"
	echo "  4. Send those commands to customer, get output, and re-analyze"
	echo ""
	echo "Options:"
	echo "  -h, --help          Show this help message"
	echo "  -v, --verbose       Verbose output (reserved for future use)"
	echo "  --run-queries       Run yum/dnf queries on THIS server (default: analyze only)"
	echo ""
	echo "Default Behavior (no options):"
	echo "  - Analyzes yumlog.txt"
	echo "  - Shows blocking chain and issue type"
	echo "  - Lists commands for customer to run for further diagnosis"
	echo "  - Suggests possible solutions"
	echo ""
	echo "With --run-queries:"
	echo "  - Runs 'yum whatprovides' and 'yum list' commands on THIS server"
	echo "  - Queries repositories to find available packages"
	echo "  - Provides specific installation commands"
	echo "  - Use ONLY if analyzing errors on the same server"
	echo ""
	echo "Output:"
	echo "  - Screen: Analysis summary and next steps"
	echo "  - File: depparse_analysis.log (comprehensive analysis)"
	echo ""
	exit 0
fi

VERBOSE=0
RUN_QUERIES=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --run-queries)
            RUN_QUERIES=1
            shift
            ;;
        -n|--no-repo)
            # Legacy option - kept for backwards compatibility
            echo "Note: -n/--no-repo is deprecated. Analysis-only is now the default."
            echo "      Use --run-queries to run repository queries."
            echo ""
            shift
            ;;
        *)
            ;;
    esac
done

echo "================================"
echo "DepParse - Dependency Analyzer"
echo "================================"

if [ "$RUN_QUERIES" -eq 1 ]; then
    echo "Mode: Running repository queries on THIS server"
    echo ""
else
    echo "Mode: Analysis only (use --run-queries to query repositories)"
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
TEMP_CONFLICTS=$(mktemp)      # Version conflicts (cannot install both)
TEMP_BLOCKERS=$(mktemp)       # Blocked updates (cannot install best candidate)
TEMP_OBSOLETES=$(mktemp)      # Obsoletes relationships
TEMP_MODULAR=$(mktemp)        # Modular package names
TEMP_TREE_DATA=$(mktemp)      # Per-problem structured data for tree display

PROBLEM_NUM=0
ISSUE_TYPE="unknown"          # Track what type of issue we detected
IS_MODULAR=0                  # Flag: modular conflict detected

# Strip arch and release suffix to show readable name-version (e.g. ant-javamail-1.10.5)
simplify_pkg() {
    echo "$1" | sed 's/\.\(noarch\|x86_64\|i686\)$//; s/-[0-9]*\.\(module\|el[0-9]\|fc[0-9]\).*$//'
}

# Map repo IDs to short labels
simplify_src() {
    case "$1" in
        @System) echo "installed" ;;
        *appstream*) echo "appstream" ;;
        *baseos*) echo "baseos" ;;
        *codeready*) echo "codeready-builder" ;;
        *) echo "$1" | sed 's/-for-.*-rpms$//; s/-rpms$//' ;;
    esac
}

# Strip module/release noise from requirement version strings
simplify_req() {
    echo "$1" | sed 's/-[0-9]*\.\(module\|el[0-9]\|fc[0-9]\)[^ ,]*//'
}

# Write header to log file
cat >> "$ANALYSIS_LOG" << EOF
================================================================================
                    DEPENDENCY ANALYSIS REPORT
================================================================================
Generated: $(date)
Source: yumlog.txt

EOF

# Parse the log and collect structured per-problem data

while read line; do
   # Track problem numbers and extract root package from Problem line
   if [[ "$line" == *"Problem"* ]]; then
       PROBLEM_NUM=$(awk '/Problem/{print $2}' <<< "$line" | tr -d ':')

       # "Problem N: package X from SOURCE requires Y, but none..."
       if [[ -n "$PROBLEM_NUM" ]] && [[ "$line" == *"package"* ]] && [[ "$line" == *"from"* ]] && [[ "$line" == *"requires"* ]]; then
           ROOT_PKG=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {print $(i+1); break}}' <<< "$line")
           ROOT_SRC=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {for(j=i+2;j<=NF;j++) if($j=="from") {print $(j+1); break}; break}}' <<< "$line")
           echo "P|$PROBLEM_NUM|ROOT|$ROOT_PKG|$ROOT_SRC" >> "$TEMP_TREE_DATA"
       fi
   fi

   # Parse "problem with installed package" lines
   if [[ "$line" == *"problem with installed package"* ]]; then
       INSTALLED_PKG=$(awk '/problem with installed package/{print $NF}' <<< $line)
       echo "$INSTALLED_PKG" >> "$TEMP_FAILPKG"
       echo "P|$PROBLEM_NUM|ROOT|$INSTALLED_PKG|@System" >> "$TEMP_TREE_DATA"
   fi

   # Parse "package requires" - extract requirement for tree display
   if [[ "$line" == *"package"* ]] && [[ "$line" == *"requires"* ]]; then
       REQ_TEXT=$(awk '/package.*requires/{
           for(i=1;i<=NF;i++) {
               if($i=="requires") {
                   req="";
                   for(j=i+1;j<=NF;j++) {
                       if($j=="but") break;
                       if($j ~ /,$/) { sub(/,$/, "", $j); req=req" "$j; break }
                       req=req" "$j;
                   }
                   sub(/^ /, "", req);
                   print req;
                   break;
               }
           }
       }' <<< "$line")
       if [ -n "$REQ_TEXT" ]; then
           echo "P|$PROBLEM_NUM|REQ|$REQ_TEXT" >> "$TEMP_TREE_DATA"
       fi
   fi

   # Parse "nothing provides" errors - these are the root causes
   if [[ "$line" == *"nothing provides"* ]]; then
       ISSUE_TYPE="missing_dependency"

       # Extract the missing dependency
       awk '{print $4}' <<< "$line" >> "$TEMP_DEPD"

       # Get the package that needs this dependency
       awk '/nothing provides/{print $NF}' <<< "$line" >> "$TEMP_FAILPKG"
       echo '--' >> "$TEMP_FAILPKG"

       # Extract missing dep info for tree display
       MISSING_DEP=$(awk '/nothing provides/{
           for(i=1;i<=NF;i++) {
               if($i=="provides") {
                   missing="";
                   for(j=i+1;j<=NF;j++) {
                       if($j=="needed") break;
                       missing=missing" "$j;
                   }
                   sub(/^ /, "", missing);
                   print missing; break;
               }
           }
       }' <<< "$line")
       NEEDED_BY=$(awk '/nothing provides/{print $NF}' <<< "$line")
       echo "P|$PROBLEM_NUM|MISSING|$MISSING_DEP|$NEEDED_BY" >> "$TEMP_TREE_DATA"
   fi

   # Parse "but none of the providers can be installed" - providers exist but blocked
   if [[ "$line" == *"but none of the providers can be installed"* ]]; then
       if [[ "$line" == *"package"* ]] && [[ "$line" == *"requires"* ]]; then
           awk '{
               for(i=1;i<=NF;i++) {
                   if($i=="package") { print $(i+1); break }
               }
           }' <<< "$line" >> "$TEMP_FAILPKG"
       fi
       if [[ "$line" == *"module+el"* ]]; then
           IS_MODULAR=1
       fi
       # (tree display built from structured data after parsing)
   fi

   # Parse "cannot install both" - version conflicts
   if [[ "$line" == *"cannot install both"* ]]; then
       ISSUE_TYPE="version_conflict"

       # Detect modular packages (version strings contain module+el)
       if [[ "$line" == *"module+el"* ]]; then
           IS_MODULAR=1
           awk '/cannot install both/{
               for(i=1;i<=NF;i++) {
                   if($i=="both") { pkg=$(i+1); gsub(/-[0-9].*/, "", pkg); print pkg }
               }
           }' <<< "$line" >> "$TEMP_MODULAR"
       fi

       # Extract the two conflicting packages
       awk '/cannot install both/{
           for(i=1;i<=NF;i++) {
               if($i=="both") {
                   # Get new version (after "both")
                   new_pkg=$(i+1);
                   # Get old version (after "and")
                   for(j=i+2;j<=NF;j++) {
                       if($j=="and") {
                           old_pkg=$(j+1);
                           break;
                       }
                   }
                   print new_pkg " ⇄ " old_pkg;
               }
           }
       }' <<< "$line" >> "$TEMP_CONFLICTS"

       # Extract conflict with source info for tree display
       awk '/cannot install both/{
           for(i=1;i<=NF;i++) {
               if($i=="both") {
                   new_pkg=$(i+1); new_src=$(i+3);
                   for(j=i+4;j<=NF;j++) {
                       if($j=="and") { old_pkg=$(j+1); old_src=$(j+3); break }
                   }
                   printf "P|PNUM|CONFLICT|%s|%s|%s|%s\n", new_pkg, new_src, old_pkg, old_src;
                   break;
               }
           }
       }' <<< "$line" | sed "s/PNUM/$PROBLEM_NUM/" >> "$TEMP_TREE_DATA"
   fi

   # Parse "cannot install the best update candidate" - blocked updates
   if [[ "$line" == *"cannot install the best update candidate"* ]]; then
       ISSUE_TYPE="blocked_update"

       if [[ "$line" == *"module+el"* ]]; then
           IS_MODULAR=1
       fi

       # Extract the package that can't be updated
       awk '/cannot install the best update candidate/{
           print $NF;
       }' <<< "$line" >> "$TEMP_BLOCKERS"

       echo "P|$PROBLEM_NUM|BLOCKED|$(awk '{print $NF}' <<< "$line")" >> "$TEMP_TREE_DATA"
   fi

   # Parse "obsoletes" relationships
   if [[ "$line" == *"obsoletes"* ]]; then
       awk '/obsoletes/{
           for(i=1;i<=NF;i++) {
               if($i=="package") pkg=$(i+1);
               if($i=="obsoletes") {
                   obs="";
                   for(j=i+1;j<=NF;j++) {
                       if($j=="provided") break;
                       obs=obs" "$j;
                   }
                   sub(/^ /, "", obs);
                   print pkg " obsoletes " obs;
               }
           }
       }' <<< "$line" >> "$TEMP_OBSOLETES"
   fi
done < yumlog.txt

# Generate visual dependency tree for the analysis log
echo "" >> "$ANALYSIS_LOG"
echo "DEPENDENCY TREE:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

if [ -s "$TEMP_TREE_DATA" ]; then
    PROB_NUMS=$(awk -F'|' '/^P\|/{print $2}' "$TEMP_TREE_DATA" | sort -un)

    for pnum in $PROB_NUMS; do
        echo "" >> "$ANALYSIS_LOG"

        # Root package
        ROOT_LINE=$(grep "^P|${pnum}|ROOT|" "$TEMP_TREE_DATA" | head -1)
        ROOT_PKG=$(echo "$ROOT_LINE" | cut -d'|' -f4)
        ROOT_SRC=$(echo "$ROOT_LINE" | cut -d'|' -f5)

        echo "Problem $pnum:" >> "$ANALYSIS_LOG"
        if [ -n "$ROOT_PKG" ]; then
            echo " $(simplify_pkg "$ROOT_PKG") ($(simplify_src "$ROOT_SRC"))" >> "$ANALYSIS_LOG"
        fi

        # Unique requirements
        PROB_REQS=$(grep "^P|${pnum}|REQ|" "$TEMP_TREE_DATA" | cut -d'|' -f4 | sort -u)
        REQ_COUNT=0
        if [ -n "$PROB_REQS" ]; then
            REQ_COUNT=$(echo "$PROB_REQS" | grep -c ".")
        fi

        # Deduplicated conflicts (by simplified base package pair)
        DEDUP_CONFLICTS=$(grep "^P|${pnum}|CONFLICT|" "$TEMP_TREE_DATA" | awk -F'|' '{
            new=$4; old=$6
            gsub(/-[0-9].*/, "", new); gsub(/-[0-9].*/, "", old)
            key = new "|" old
            if (!seen[key]++) print $0
        }')
        CONFLICT_COUNT=0
        if [ -n "$DEDUP_CONFLICTS" ]; then
            CONFLICT_COUNT=$(echo "$DEDUP_CONFLICTS" | grep -c "^P|")
        fi

        # Blocked updates
        PROB_BLOCKED=$(grep "^P|${pnum}|BLOCKED|" "$TEMP_TREE_DATA" | cut -d'|' -f4 | sort -u)
        HAS_BLOCKED=0
        if [ -n "$PROB_BLOCKED" ]; then HAS_BLOCKED=1; fi

        # Missing deps
        PROB_MISSING=$(grep "^P|${pnum}|MISSING|" "$TEMP_TREE_DATA" 2>/dev/null)
        MISSING_COUNT=0
        if [ -n "$PROB_MISSING" ]; then
            MISSING_COUNT=$(echo "$PROB_MISSING" | grep -c "^P|")
        fi

        # Render requirement branches
        REQ_IDX=0
        if [ -n "$PROB_REQS" ] && [ "$REQ_COUNT" -gt 0 ]; then
            while IFS= read -r req; do
                [ -z "$req" ] && continue
                REQ_IDX=$((REQ_IDX + 1))
                RP="├──"; RC="│   "
                [ "$REQ_IDX" -eq "$REQ_COUNT" ] && { RP="└──"; RC="    "; }

                echo " $RP requires: $(simplify_req "$req")" >> "$ANALYSIS_LOG"

                # Children: conflict pairs (2 lines each) + blocked
                CHILD_COUNT=$(( CONFLICT_COUNT * 2 + HAS_BLOCKED ))
                CHILD_IDX=0

                # Show each unique conflict as old ←→ new pair
                if [ -n "$DEDUP_CONFLICTS" ]; then
                    while IFS='|' read -r _ _ _ new_pkg new_src old_pkg old_src; do
                        [ -z "$new_pkg" ] && continue
                        CHILD_IDX=$((CHILD_IDX + 1))
                        CP="├──"; [ "$CHILD_IDX" -eq "$CHILD_COUNT" ] && CP="└──"
                        echo " $RC $CP $(simplify_pkg "$old_pkg") ($(simplify_src "$old_src")) -- CONFLICTS with $(simplify_pkg "$new_pkg") ($(simplify_src "$new_src"))" >> "$ANALYSIS_LOG"

                        CHILD_IDX=$((CHILD_IDX + 1))
                        CP="├──"; [ "$CHILD_IDX" -eq "$CHILD_COUNT" ] && CP="└──"
                        echo " $RC $CP $(simplify_pkg "$new_pkg") ($(simplify_src "$new_src")) -- cannot coexist with $(simplify_pkg "$old_pkg")" >> "$ANALYSIS_LOG"
                    done <<< "$DEDUP_CONFLICTS"
                fi

                # Show blocked updates summary
                if [ "$HAS_BLOCKED" -eq 1 ]; then
                    BNAMES=""
                    while IFS= read -r bp; do
                        [ -z "$bp" ] && continue
                        [ -n "$BNAMES" ] && BNAMES="$BNAMES, "
                        BNAMES="$BNAMES$(simplify_pkg "$bp")"
                    done <<< "$PROB_BLOCKED"
                    echo " $RC └── BLOCKED UPDATES: $BNAMES" >> "$ANALYSIS_LOG"
                fi
            done <<< "$PROB_REQS"
        fi

        # Show missing dependencies if any (for "nothing provides" errors)
        if [ -n "$PROB_MISSING" ] && [ "$MISSING_COUNT" -gt 0 ]; then
            MISS_IDX=0
            while IFS='|' read -r _ _ _ missing_dep needed_by; do
                [ -z "$missing_dep" ] && continue
                MISS_IDX=$((MISS_IDX + 1))
                MP="├──"; [ "$MISS_IDX" -eq "$MISSING_COUNT" ] && MP="└──"
                echo " $MP MISSING: $missing_dep (needed by $(simplify_pkg "$needed_by"))" >> "$ANALYSIS_LOG"
            done <<< "$PROB_MISSING"
        fi
    done
else
    echo "No dependency problems detected." >> "$ANALYSIS_LOG"
fi

# Analyze issue type and add appropriate sections
echo "" >> "$ANALYSIS_LOG"
echo "" >> "$ANALYSIS_LOG"
echo "ISSUE TYPE ANALYSIS:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

# Determine the primary issue type
if [ "$IS_MODULAR" -eq 1 ] && ([ -s "$TEMP_CONFLICTS" ] || [ -s "$TEMP_BLOCKERS" ]); then
    ISSUE_TYPE="modular_conflict"
    echo "Type: DNF MODULE STREAM CONFLICT" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Packages from different DNF module streams are conflicting." >> "$ANALYSIS_LOG"
    echo "This occurs when installed packages belong to one module stream but" >> "$ANALYSIS_LOG"
    echo "the update requires packages from a different stream." >> "$ANALYSIS_LOG"
    if [ -s "$TEMP_MODULAR" ]; then
        echo "" >> "$ANALYSIS_LOG"
        echo "Detected modular packages:" >> "$ANALYSIS_LOG"
        sort -u "$TEMP_MODULAR" | awk '{printf "  • %s\n", $0}' >> "$ANALYSIS_LOG"
    fi
elif [ -s "$TEMP_CONFLICTS" ] && [ -s "$TEMP_BLOCKERS" ]; then
    ISSUE_TYPE="circular_dependency"
    echo "Type: CIRCULAR DEPENDENCY / VERSION CONFLICT LOCK" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Multiple packages have version conflicts that create a circular dependency." >> "$ANALYSIS_LOG"
    echo "These packages must be upgraded together in a single transaction." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_CONFLICTS" ]; then
    ISSUE_TYPE="version_conflict"
    echo "Type: VERSION CONFLICT" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Cannot install both old and new versions of the same package simultaneously." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_BLOCKERS" ]; then
    ISSUE_TYPE="blocked_update"
    echo "Type: BLOCKED UPDATE" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Packages cannot be updated to their best available versions." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_DEPD" ]; then
    ISSUE_TYPE="missing_dependency"
    echo "Type: MISSING DEPENDENCY" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Required packages or libraries are not available in enabled repositories." >> "$ANALYSIS_LOG"
else
    ISSUE_TYPE="unknown"
    echo "Type: UNKNOWN or NO ISSUES DETECTED" >> "$ANALYSIS_LOG"
fi

# Build blocking chain for circular dependencies and version conflicts
if [ "$ISSUE_TYPE" = "modular_conflict" ] || [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ]; then
    echo "" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "BLOCKING CHAIN ANALYSIS:" >> "$ANALYSIS_LOG"
    echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"

    # Extract base package names from conflicts
    if [ -s "$TEMP_CONFLICTS" ]; then
        # Get unique base package names (strip version info)
        CONFLICT_PKGS=$(cat "$TEMP_CONFLICTS" | awk '{print $1, $3}' | tr ' ' '\n' | sed 's/-[0-9].*//' | sort -u)

        # For each conflicting package, show what's being attempted
        for base_pkg in $CONFLICT_PKGS; do
            # Find old and new versions from conflicts
            OLD_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')
            NEW_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')

            if [ -n "$OLD_VER" ] && [ -n "$NEW_VER" ]; then
                echo "UPDATE ATTEMPT: $base_pkg" >> "$ANALYSIS_LOG"
                echo "  INSTALLED: $base_pkg-$OLD_VER" >> "$ANALYSIS_LOG"
                echo "  TRYING TO INSTALL: $base_pkg-$NEW_VER" >> "$ANALYSIS_LOG"
                echo "  ↓ BLOCKED BY: Cannot install both versions simultaneously" >> "$ANALYSIS_LOG"

                # Check if this package is also in blockers list
                if grep -q "^$base_pkg-" "$TEMP_BLOCKERS" 2>/dev/null; then
                    echo "  ↓ REASON: Other packages depend on old version" >> "$ANALYSIS_LOG"
                fi
                echo "" >> "$ANALYSIS_LOG"
            fi
        done

        echo "ROOT CAUSE:" >> "$ANALYSIS_LOG"
        echo "  All these packages form an interdependent group that must upgrade together." >> "$ANALYSIS_LOG"
        echo "  DNF cannot auto-resolve because upgrading one breaks the others." >> "$ANALYSIS_LOG"
        echo "" >> "$ANALYSIS_LOG"
        echo "AFFECTED PACKAGE GROUP:" >> "$ANALYSIS_LOG"
        for pkg in $CONFLICT_PKGS; do
            echo "  • $pkg" >> "$ANALYSIS_LOG"
        done
    fi
fi

# Add version conflicts section if any were found
if [ -s "$TEMP_CONFLICTS" ]; then
    echo "" >> "$ANALYSIS_LOG"
    echo "VERSION CONFLICTS DETECTED:" >> "$ANALYSIS_LOG"
    echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
    cat "$TEMP_CONFLICTS" | sort -u >> "$ANALYSIS_LOG"
fi

# Add blocked updates section if any were found
if [ -s "$TEMP_BLOCKERS" ]; then
    echo "" >> "$ANALYSIS_LOG"
    echo "BLOCKED PACKAGE UPDATES:" >> "$ANALYSIS_LOG"
    echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
    cat "$TEMP_BLOCKERS" | sort -u >> "$ANALYSIS_LOG"
fi

# Add missing dependencies section if any were found
echo "" >> "$ANALYSIS_LOG"
echo "" >> "$ANALYSIS_LOG"
echo "ROOT CAUSE - MISSING DEPENDENCIES:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

if [ -s "$TEMP_DEPD" ]; then
    cat "$TEMP_DEPD" | sort -u >> "$ANALYSIS_LOG"

    # Only query repositories if --run-queries is specified
    if [ "$RUN_QUERIES" -eq 1 ]; then
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
        echo "REPOSITORY ANALYSIS: SKIPPED (analysis-only mode)" >> "$ANALYSIS_LOG"
        echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
        echo "Repository queries were not run. Use --run-queries to query packages on this server." >> "$ANALYSIS_LOG"
    fi
else
    echo "No dependency issues found" >> "$ANALYSIS_LOG"
fi

# Display summary to stdout
echo ""
echo "================================"
echo "ANALYSIS COMPLETE"
echo "================================"

# Check if any problems were found (check all temp files)
PROBLEMS_FOUND=0
PROBLEM_COUNT=0

if [ -s "$TEMP_DEPD" ] || [ -s "$TEMP_CONFLICTS" ] || [ -s "$TEMP_BLOCKERS" ]; then
    PROBLEMS_FOUND=1
fi

# Count problems from log file
if [ -f "$ANALYSIS_LOG" ]; then
    PROBLEM_COUNT=$(grep -c "^Problem [0-9]" "$ANALYSIS_LOG" 2>/dev/null || echo "0")
fi

if [ "$PROBLEMS_FOUND" -eq 1 ]; then
    echo "Issue Type: $ISSUE_TYPE"
    echo "Found $PROBLEM_COUNT dependency problem(s)"
    echo ""

    # Show blocking chain summary for version conflicts
    if [ "$ISSUE_TYPE" = "modular_conflict" ] || [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ]; then
        echo "BLOCKING CHAIN:"
        echo "--------------------"
        echo ""

        # Show detailed blocking relationships from the analysis
        # Extract the key blockers and show their dependency chains

        # Show main conflict packages
        if [ -s "$TEMP_CONFLICTS" ]; then
            # Get unique base package names
            CONFLICT_PKGS=$(cat "$TEMP_CONFLICTS" | awk '{print $1, $3}' | tr ' ' '\n' | sed 's/-[0-9].*//' | sort -u)

            # For samba-like conflicts, identify the key chain
            if echo "$CONFLICT_PKGS" | grep -q "samba-client-libs"; then
                echo "TRYING TO UPDATE: samba-client-libs"
                OLD=$(grep "samba-client-libs" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/')
                NEW=$(grep "samba-client-libs" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/')
                echo "  Current: $OLD"
                echo "  Trying: $NEW"
                echo "  ↓"

                # Check what it requires from the detailed chains
                if grep -q "samba-client-libs.*requires.*libldb" "$ANALYSIS_LOG"; then
                    echo "  REQUIRES: libldb = $NEW"
                    echo "    ↓"

                    # Check libldb conflict
                    if grep -q "^libldb" "$TEMP_CONFLICTS"; then
                        LIBLDB_OLD=$(grep "^libldb" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/')
                        LIBLDB_NEW=$(grep "^libldb" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/')
                        echo "    BLOCKED: Cannot install libldb-$LIBLDB_NEW"
                        echo "    ├─ INSTALLED: libldb-$LIBLDB_OLD"
                        echo "    └─ CONFLICT: Cannot have both versions"

                        # Check if something holds it back
                        if grep -q "^libldb.*BLOCKED" "$ANALYSIS_LOG"; then
                            echo "       ↓"
                            echo "       WHY? Other packages need old version"
                        fi
                    fi
                fi
                echo ""
            fi

            # Show all interdependent packages
            echo "INTERDEPENDENT PACKAGES:"
            for pkg in $CONFLICT_PKGS; do
                OLD=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                NEW=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)

                if [ -n "$OLD" ] && [ -n "$NEW" ]; then
                    BLOCKED=""
                    if grep -q "^$pkg-.*\.x86_64$" "$TEMP_BLOCKERS" 2>/dev/null; then
                        BLOCKED=" [HELD BACK]"
                    fi
                    echo "  • $pkg: $OLD → $NEW$BLOCKED"
                fi
            done
        fi

        echo ""
        if [ "$ISSUE_TYPE" = "modular_conflict" ]; then
            echo "ROOT CAUSE: DNF module stream conflict"
            echo "  Installed packages belong to one module stream but repos have a newer stream."
            echo "  Use 'dnf module list' and 'dnf module reset' to resolve."
        else
            echo "ROOT CAUSE: Circular dependency lock"
            echo "  All packages must upgrade together in one transaction"
        fi
        echo ""
    fi

    # Count affected packages
    AFFECTED_COUNT=$(cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | sort -u | wc -l)

    # Show affected packages only for missing dependency type
    if [ "$ISSUE_TYPE" = "missing_dependency" ] && [ "$AFFECTED_COUNT" -gt 0 ]; then
        echo "Affected Packages ($AFFECTED_COUNT):"
        echo "--------------------"
        cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | awk '{print $1}' | sed 's/-[0-9].*$//' | sort -u | \
            awk '{printf "  • %s\n", $0}'
        echo ""
    fi

    # Show missing dependencies
    DEP_COUNT=$(cat "$TEMP_DEPD" | sort -u | wc -l)
    if [ "$DEP_COUNT" -gt 0 ]; then
        echo "Missing Dependencies ($DEP_COUNT):"
        echo "--------------------"
        cat "$TEMP_DEPD" | sort -u | head -10 | awk '{printf "  • %s\n", $0}'
        if [ "$DEP_COUNT" -gt 10 ]; then
            echo "  ... and $((DEP_COUNT - 10)) more (see log file)"
        fi
        echo ""
    fi

    # Show troubleshooting commands based on issue type
    echo "================================"
    echo "TROUBLESHOOTING STEPS"
    echo "================================"
    echo ""
    echo "Run these commands on the customer system and send back the output:"
    echo ""

    if [ "$ISSUE_TYPE" = "modular_conflict" ]; then
        MODULE_PKGS=$(sort -u "$TEMP_MODULAR" | tr '\n' ' ')

        echo "STEP 1: Identify affected module streams"
        echo "-----------------------------------------"
        for pkg in $MODULE_PKGS; do
            echo "dnf module list $pkg"
        done
        echo ""

        echo "STEP 2: Check for version locks and excludes"
        echo "---------------------------------------------"
        echo "dnf config-manager --dump | grep -E \"^exclude|^excludepkgs\""
        echo "yum versionlock list 2>/dev/null"
        echo ""

        echo "STEP 3: List installed modular packages"
        echo "----------------------------------------"
        echo "dnf module list --installed"
        echo ""

        echo "================================"
        echo "POSSIBLE SOLUTIONS"
        echo "================================"
        echo ""
        echo "Option 1: Reset module stream and retry update"
        echo "-----------------------------------------------"
        for pkg in $MODULE_PKGS; do
            echo "  dnf module reset $pkg"
        done
        echo "  dnf update"
        echo ""

        echo "Option 2: Switch to the newer module stream"
        echo "---------------------------------------------"
        for pkg in $MODULE_PKGS; do
            echo "  dnf module switch-to $pkg"
        done
        echo ""

        echo "Option 3: Remove blocking sub-packages, then update"
        echo "----------------------------------------------------"
        HOLDING_PKGS=$(cat "$TEMP_FAILPKG" 2>/dev/null | grep -v "^--$" | grep -v "^$" | sed 's/-[0-9].*//' | sort -u)
        if [ -n "$HOLDING_PKGS" ]; then
            for pkg in $HOLDING_PKGS; do
                echo "  dnf remove $pkg"
            done
            echo "  # Then run: dnf update"
        fi
        echo ""

        echo "Option 4: Force update with --allowerasing"
        echo "--------------------------------------------"
        echo "  dnf update --allowerasing $MODULE_PKGS"
        echo "  (CAUTION: Review what will be removed before confirming)"
        echo ""

    elif [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ]; then
        # Get the list of conflicting packages
        CONFLICT_PKGS=$(cat "$TEMP_CONFLICTS" | awk '{print $1, $3}' | tr ' ' '\n' | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')

        echo "STEP 1: Check for excludes (most common cause)"
        echo "-----------------------------------------------"
        echo "dnf config-manager --dump | grep -E \"^exclude|^excludepkgs\""
        echo "yum versionlock list"
        echo ""

        echo "STEP 2: Verify packages are available in repositories"
        echo "------------------------------------------------------"
        echo "yum list --showduplicates $CONFLICT_PKGS | head -50"
        echo ""

        echo "STEP 3: Check what's holding packages back"
        echo "-------------------------------------------"
        # Show rpm -q --whatrequires for key blockers
        if [ -s "$TEMP_BLOCKERS" ]; then
            BLOCKER_PKGS=$(cat "$TEMP_BLOCKERS" | sed 's/-[0-9].*//' | sort -u | head -3)
            for pkg in $BLOCKER_PKGS; do
                echo "rpm -q --whatrequires $pkg"
            done
        fi
        echo ""

        echo "STEP 4: Simulate coordinated update"
        echo "------------------------------------"
        echo "dnf update $CONFLICT_PKGS --assumeno"
        echo ""

        echo "================================"
        echo "POSSIBLE SOLUTIONS"
        echo "================================"
        echo ""
        echo "IF no excludes found (Step 1) AND packages available (Step 2):"
        echo "  → Try coordinated update of entire group:"
        echo "    dnf update $CONFLICT_PKGS"
        echo ""
        echo "IF that fails with conflicts:"
        echo "  → Use allowerasing (CAUTION: review what will be removed):"
        echo "    dnf update --allowerasing $CONFLICT_PKGS"
        echo ""
        echo "IF excludes ARE found in Step 1:"
        echo "  → Remove exclude from config OR use:"
        echo "    dnf update --disableexcludes=all $CONFLICT_PKGS"
        echo ""

    elif [ "$ISSUE_TYPE" = "blocked_update" ]; then
        BLOCKER_PKGS=$(cat "$TEMP_BLOCKERS" | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')

        echo "STEP 1: Check for excludes"
        echo "---------------------------"
        echo "dnf config-manager --dump | grep -E \"^exclude|^excludepkgs\""
        echo "yum versionlock list"
        echo ""

        echo "STEP 2: Check what's available"
        echo "-------------------------------"
        echo "yum list --showduplicates $BLOCKER_PKGS"
        echo ""

        echo "STEP 3: Simulate update"
        echo "-----------------------"
        echo "dnf update $BLOCKER_PKGS --assumeno"
        echo ""

    elif [ "$ISSUE_TYPE" = "missing_dependency" ]; then
        if [ -s "$TEMP_DEPD" ]; then
            DEP_LIST=$(cat "$TEMP_DEPD" | sort -u | head -5 | tr '\n' ' ')

            echo "STEP 1: Check repository status"
            echo "--------------------------------"
            echo "yum repolist enabled"
            echo ""

            echo "STEP 2: Check if dependencies are available"
            echo "--------------------------------------------"
            for dep in $DEP_LIST; do
                echo "yum whatprovides \"$dep\""
            done
            echo ""

            echo "STEP 3: Check for excludes"
            echo "---------------------------"
            echo "dnf config-manager --dump | grep -E \"^exclude|^excludepkgs\""
            echo ""

            if [ -n "$FIX_COMMAND" ]; then
                echo "POSSIBLE SOLUTION:"
                echo "------------------"
                echo "$FIX_COMMAND"
                echo ""
            fi
        fi
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
rm -f "$TEMP_FAILPKG" "$TEMP_DEPD" "$TEMP_CONFLICTS" "$TEMP_BLOCKERS" "$TEMP_OBSOLETES" "$TEMP_MODULAR" "$TEMP_TREE_DATA" 2>/dev/null
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
