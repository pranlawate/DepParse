#!/bin/bash

if  [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	echo "DepParse - YUM/DNF Dependency Error Analyzer"
	echo "============================================="
	echo ""
	echo "Usage: ./yumlooper.sh [OPTIONS] [LOGFILE]"
	echo ""
	echo "This tool analyzes yum/dnf dependency errors and provides troubleshooting guidance."
	echo ""
	echo "Steps:"
	echo "  1. Get the dependency error from customer: dnf update 2>&1 | tee yumlog.txt"
	echo "  2. Run: ./yumlooper.sh [logfile]"
	echo "  3. Script analyzes the error and shows commands to run for diagnosis"
	echo "  4. Send those commands to customer, get output, and re-analyze"
	echo ""
	echo "Arguments:"
	echo "  LOGFILE             Path to yum/dnf log file (default: yumlog.txt)"
	echo ""
	echo "Options:"
	echo "  -h, --help          Show this help message"
	echo "  -v, --verbose       Verbose output (reserved for future use)"
	echo "  --run-queries       Run yum/dnf queries on THIS server (default: analyze only)"
	echo ""
	echo "Examples:"
	echo "  ./yumlooper.sh                        # reads yumlog.txt in current dir"
	echo "  ./yumlooper.sh /tmp/customer_log.txt   # reads specified file"
	echo "  ./yumlooper.sh mylog.txt --run-queries # reads mylog.txt + queries repos"
	echo ""
	echo "Default Behavior (no options):"
	echo "  - Analyzes the log file (yumlog.txt or specified file)"
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
	echo "Supported Error Patterns:"
	echo "  - 'nothing provides' (missing dependency)"
	echo "  - 'problem with installed package'"
	echo "  - 'cannot install both' (version conflict)"
	echo "  - 'cannot install the best update candidate'"
	echo "  - 'does not belong to a distupgrade repository'"
	echo "  - 'obsoletes' relationships"
	echo ""
	echo "Output:"
	echo "  - Screen: Analysis summary and next steps"
	echo "  - File: depparse_analysis.log (comprehensive analysis)"
	echo ""
	exit 0
fi

VERBOSE=0
RUN_QUERIES=0
LOGFILE="yumlog.txt"

# Parse arguments
for arg in "$@"; do
    case $arg in
        -v|--verbose)
            VERBOSE=1
            ;;
        --run-queries)
            RUN_QUERIES=1
            ;;
        -n|--no-repo)
            echo "Note: -n/--no-repo is deprecated. Analysis-only is now the default."
            echo "      Use --run-queries to run repository queries."
            echo ""
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Use -h or --help for usage."
            exit 1
            ;;
        *)
            LOGFILE="$arg"
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

echo "Step 1: Parsing $LOGFILE..."

# Check if input file exists
if [ ! -f "$LOGFILE" ]; then
    echo ""
    echo "ERROR: $LOGFILE not found!"
    echo ""
    echo "Usage: ./yumlooper.sh [OPTIONS] [LOGFILE]"
    echo "Default logfile: yumlog.txt"
    echo "Example: dnf update 2>&1 | tee yumlog.txt"
    echo ""
    exit 1
fi

# Check if input file is empty
if [ ! -s "$LOGFILE" ]; then
    echo ""
    echo "ERROR: $LOGFILE is empty!"
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
TEMP_DISTUPGRADE=$(mktemp)    # Packages blocked by distupgrade repo check
TEMP_TREE_DATA=$(mktemp)      # Per-problem structured data for tree display

PROBLEM_NUM=0
ISSUE_TYPE="unknown"          # Track what type of issue we detected
IS_MODULAR=0                  # Flag: modular conflict detected

# Strip arch and distro tag, keep release number (e.g. ant-javamail-1.10.5-1)
simplify_pkg() {
    echo "$1" | sed 's/\.\(noarch\|x86_64\|i686\)$//; s/\.module[^.]*.*$//; s/\.el[0-9][^.]*//; s/\.fc[0-9][^.]*//'
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
Source: $LOGFILE

EOF

# Parse the log and collect structured per-problem data
CURRENT_ROOT_BASE=""

while read line; do
   # Track problem numbers and extract root package from Problem line
   if [[ "$line" == *"Problem"* ]]; then
       PROBLEM_NUM=$(awk '/Problem/{print $2}' <<< "$line" | tr -d ':')
       CURRENT_ROOT_BASE=""

       # "Problem N: package X from SOURCE requires Y, but none..."
       if [[ -n "$PROBLEM_NUM" ]] && [[ "$line" == *"package"* ]] && [[ "$line" == *"from"* ]] && [[ "$line" == *"requires"* ]]; then
           ROOT_PKG=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {print $(i+1); break}}' <<< "$line")
           ROOT_SRC=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {for(j=i+2;j<=NF;j++) if($j=="from") {print $(j+1); break}; break}}' <<< "$line")
           CURRENT_ROOT_BASE=$(echo "$ROOT_PKG" | sed 's/\.\(noarch\|x86_64\|i686\)$//')
           echo "P|$PROBLEM_NUM|ROOT|$ROOT_PKG|$ROOT_SRC" >> "$TEMP_TREE_DATA"

           # Chain tracking: root package needs its requirement
           ROOT_BASE=$(echo "$ROOT_PKG" | sed 's/-[0-9].*//')
           ROOT_REQ_SYM=$(awk '{for(i=1;i<=NF;i++) if($i=="requires") {print $(i+1); break}}' <<< "$line")
           ROOT_REQ_BASE=$(echo "$ROOT_REQ_SYM" | sed 's/[><=].*//')
           if [ -n "$ROOT_BASE" ] && [ -n "$ROOT_REQ_BASE" ]; then
               echo "P|$PROBLEM_NUM|NEEDS|$ROOT_BASE|$ROOT_REQ_BASE" >> "$TEMP_TREE_DATA"
           fi
       fi
   fi

   # Parse "problem with installed package" lines
   if [[ "$line" == *"problem with installed package"* ]]; then
       INSTALLED_PKG=$(awk '/problem with installed package/{print $NF}' <<< $line)
       CURRENT_ROOT_BASE=$(echo "$INSTALLED_PKG" | sed 's/\.\(noarch\|x86_64\|i686\)$//')
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
           BLOCKED_PKG=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {print $(i+1); break}}' <<< "$line")
           echo "$BLOCKED_PKG" >> "$TEMP_FAILPKG"

           # If this package matches the root, track the additional source
           BLOCKED_BASE=$(echo "$BLOCKED_PKG" | sed 's/\.\(noarch\|x86_64\|i686\)$//')
           if [ -n "$CURRENT_ROOT_BASE" ] && [ "$BLOCKED_BASE" = "$CURRENT_ROOT_BASE" ]; then
               BLOCKED_SRC=$(awk '{for(i=1;i<=NF;i++) if($i=="package") {for(j=i+2;j<=NF;j++) if($j=="from") {print $(j+1); break}; break}}' <<< "$line")
               echo "P|$PROBLEM_NUM|ROOT|$BLOCKED_PKG|$BLOCKED_SRC" >> "$TEMP_TREE_DATA"
           fi

           # Chain tracking: record "X needs Y" edge
           # Extract the requirer base name and what it requires
           REQUIRER_BASE=$(echo "$BLOCKED_PKG" | sed 's/-[0-9].*//')
           REQUIRED_SYM=$(awk '{for(i=1;i<=NF;i++) if($i=="requires") {print $(i+1); break}}' <<< "$line")
           REQUIRED_BASE=$(echo "$REQUIRED_SYM" | sed 's/[><=].*//')
           if [ -n "$REQUIRER_BASE" ] && [ -n "$REQUIRED_BASE" ]; then
               echo "P|$PROBLEM_NUM|NEEDS|$REQUIRER_BASE|$REQUIRED_BASE" >> "$TEMP_TREE_DATA"
           fi
       fi
       if [[ "$line" == *"module+el"* ]]; then
           IS_MODULAR=1
       fi
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

   # Parse "does not belong to a distupgrade repository" - upgrade target mismatch
   if [[ "$line" == *"does not belong to a distupgrade repository"* ]]; then
       ISSUE_TYPE="filtered_dependency_gap"
       pkg=$(echo "$line" | sed 's/^ *- *//' | awk '{print $1}')
       repo=$(echo "$line" | grep -oP 'from \K\S+')
       echo "$pkg|$repo" >> "$TEMP_DISTUPGRADE"
       echo "P|$PROBLEM_NUM|DISTUPGRADE|$pkg|$repo" >> "$TEMP_TREE_DATA"
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
done < "$LOGFILE"

# ============================================================================
# CHAIN ANALYSIS: trace dependency chains to find the REAL root cause
# ============================================================================
# DNF logs are inverted: they blame the top-level package when the real issue
# is a dependency further down the chain that can't resolve. We trace the
# chain to find the terminal failure (the actual root cause).
#
# Terminal failures (real root causes):
#   - DISTUPGRADE: package outside the update scope (--security/--advisory/distro-sync)
#   - MISSING: "nothing provides" - dependency not in any enabled repo
#   - CONFLICT at end of chain: version clash at the bottom of the dep tree
#
# Installed blockers (genuinely pinning):
#   - "problem with installed package" (ROOT source = @System)
#   - These packages ARE the root cause: they're installed, have no update,
#     and their version requirements hold back other packages
#
# Victims (NOT the root cause despite DNF blaming them):
#   - "cannot install the best update candidate" packages that are NOT
#     genuinely installed blockers - they WANT to update but can't because
#     their dependency chain is broken somewhere downstream
# ============================================================================

# Collect genuinely installed blockers (from "problem with installed package")
INSTALLED_BLOCKER_PKGS=""
if [ -s "$TEMP_TREE_DATA" ]; then
    INSTALLED_BLOCKER_PKGS=$(grep '|ROOT|.*|@System' "$TEMP_TREE_DATA" | cut -d'|' -f4 | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')
fi

# Collect terminal failure packages (the REAL root causes)
TERMINAL_PKGS=""
if [ -s "$TEMP_DISTUPGRADE" ]; then
    TERMINAL_PKGS=$(awk -F'|' '{print $1}' "$TEMP_DISTUPGRADE" | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')
fi
if [ -s "$TEMP_DEPD" ]; then
    # "nothing provides" - the missing dep symbols (may not be package names)
    TERMINAL_PKGS="$TERMINAL_PKGS$(cat "$TEMP_DEPD" | sort -u | tr '\n' ' ')"
fi

# Collect packages from conflicts (at the end of chains)
CONFLICT_PKGS_ALL=""
if [ -s "$TEMP_CONFLICTS" ]; then
    CONFLICT_PKGS_ALL=$(cat "$TEMP_CONFLICTS" | awk '{print $1, $3}' | tr ' ' '\n' | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')
fi

# Collect packages from blockers
BLOCKER_PKGS_ALL=""
if [ -s "$TEMP_BLOCKERS" ]; then
    BLOCKER_PKGS_ALL=$(cat "$TEMP_BLOCKERS" | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')
fi

# Build the NEEDS chain from TREE_DATA
# NEEDS entries: P|NUM|NEEDS|requirer_base|required_base
# Follow the chain: A needs B, B needs C → chain is A → B → C
# The package at the END of the chain with a terminal failure is the root cause

# Find chain endpoints: packages that are NEEDED but don't NEED anything else
CHAIN_NEEDERS=""   # packages that require something
CHAIN_NEEDED=""    # packages that are required by something
if [ -s "$TEMP_TREE_DATA" ]; then
    CHAIN_NEEDERS=$(grep '|NEEDS|' "$TEMP_TREE_DATA" | cut -d'|' -f4 | sort -u | tr '\n' ' ')
    CHAIN_NEEDED=$(grep '|NEEDS|' "$TEMP_TREE_DATA" | cut -d'|' -f5 | sort -u | tr '\n' ' ')
fi

# Chain endpoints = packages that are NEEDED but don't NEED anything themselves
CHAIN_ENDPOINTS=""
for needed_pkg in $CHAIN_NEEDED; do
    IS_NEEDER=0
    for needer_pkg in $CHAIN_NEEDERS; do
        if [ "$needed_pkg" = "$needer_pkg" ]; then
            IS_NEEDER=1
            break
        fi
    done
    if [ "$IS_NEEDER" -eq 0 ]; then
        CHAIN_ENDPOINTS="$CHAIN_ENDPOINTS $needed_pkg"
    fi
done

# Now classify: HOLDING_BACK vs HELD_BACK vs VICTIM
# HOLDING_BACK: genuinely installed packages that pin versions (from "problem with installed package")
# CHAIN_ROOT_CAUSE: terminal failure packages at end of dependency chain
# VICTIM: packages in BLOCKERS that are neither installed blockers nor terminals
HOLDING_BACK_PKGS=""
HELD_BACK_PKGS=""
VICTIM_PKGS=""
CHAIN_ROOT_CAUSE=""

# Determine the actual root cause packages
if [ -n "$TERMINAL_PKGS" ]; then
    # Terminal failures exist - these are the root cause
    CHAIN_ROOT_CAUSE="$TERMINAL_PKGS"
fi

# Check installed blockers
for ipkg in $INSTALLED_BLOCKER_PKGS; do
    # Installed blocker is a genuine blocker ONLY if it's not also a victim
    # (i.e., it's not trying to update itself via a terminal failure)
    IS_TERMINAL=0
    for tpkg in $TERMINAL_PKGS; do
        if [ "$ipkg" = "$tpkg" ]; then IS_TERMINAL=1; break; fi
    done
    if [ "$IS_TERMINAL" -eq 0 ]; then
        [ -n "$HOLDING_BACK_PKGS" ] && HOLDING_BACK_PKGS="$HOLDING_BACK_PKGS "
        HOLDING_BACK_PKGS="$HOLDING_BACK_PKGS$ipkg"
    fi
done

# Classify conflict packages
if [ -n "$CONFLICT_PKGS_ALL" ]; then
    HELD_BACK_PKGS="$CONFLICT_PKGS_ALL"
fi

# Classify blocker packages: victim if not an installed blocker and not a terminal
for bpkg in $BLOCKER_PKGS_ALL; do
    IS_INSTALLED=0
    for ipkg in $INSTALLED_BLOCKER_PKGS; do
        if [ "$bpkg" = "$ipkg" ]; then IS_INSTALLED=1; break; fi
    done
    IS_TERMINAL=0
    for tpkg in $TERMINAL_PKGS; do
        if [ "$bpkg" = "$tpkg" ]; then IS_TERMINAL=1; break; fi
    done
    IS_CONFLICT=0
    for cpkg in $CONFLICT_PKGS_ALL; do
        if [ "$bpkg" = "$cpkg" ]; then IS_CONFLICT=1; break; fi
    done
    if [ "$IS_INSTALLED" -eq 0 ] && [ "$IS_TERMINAL" -eq 0 ] && [ "$IS_CONFLICT" -eq 0 ]; then
        VICTIM_PKGS="$VICTIM_PKGS $bpkg"
    fi
done

# Generate visual dependency tree for the analysis log
echo "" >> "$ANALYSIS_LOG"
echo "Dependency tree:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

if [ -s "$TEMP_TREE_DATA" ]; then
    # Group problems by root package base name to merge duplicates
    PROB_NUMS=$(awk -F'|' '/^P\|/{print $2}' "$TEMP_TREE_DATA" | sort -un)
    ROOT_BASES_SEEN=""
    TREE_IDX=0

    for pnum in $PROB_NUMS; do
        ROOT_PKG=$(grep "^P|${pnum}|ROOT|" "$TEMP_TREE_DATA" | head -1 | cut -d'|' -f4)
        [ -z "$ROOT_PKG" ] && continue
        THIS_BASE=$(echo "$ROOT_PKG" | sed 's/-[0-9].*//')

        # Skip if we already rendered a tree for this root base name
        ALREADY_SEEN=0
        for seen in $ROOT_BASES_SEEN; do
            if [ "$seen" = "$THIS_BASE" ]; then ALREADY_SEEN=1; break; fi
        done
        [ "$ALREADY_SEEN" -eq 1 ] && continue
        ROOT_BASES_SEEN="$ROOT_BASES_SEEN $THIS_BASE"

        # Collect all problem numbers sharing this root base
        GROUP_PNUMS=""
        for check_pnum in $PROB_NUMS; do
            CHECK_PKG=$(grep "^P|${check_pnum}|ROOT|" "$TEMP_TREE_DATA" | head -1 | cut -d'|' -f4)
            CHECK_BASE=$(echo "$CHECK_PKG" | sed 's/-[0-9].*//')
            if [ "$CHECK_BASE" = "$THIS_BASE" ]; then
                GROUP_PNUMS="$GROUP_PNUMS $check_pnum"
            fi
        done

        TREE_IDX=$((TREE_IDX + 1))
        echo "" >> "$ANALYSIS_LOG"

        # Combine sources from all problems in the group
        SRC_DISPLAY=""
        for gp in $GROUP_PNUMS; do
            while IFS= read -r src; do
                [ -z "$src" ] && continue
                s=$(simplify_src "$src")
                if [ -z "$SRC_DISPLAY" ]; then
                    SRC_DISPLAY="$s"
                elif [[ "$SRC_DISPLAY" != *"$s"* ]]; then
                    SRC_DISPLAY="$SRC_DISPLAY + $s"
                fi
            done <<< "$(grep "^P|${gp}|ROOT|" "$TEMP_TREE_DATA" | cut -d'|' -f5 | sort -u)"
        done

        ROOT_SIMPLE=$(simplify_pkg "$ROOT_PKG")
        ROOT_BASE=$(echo "$ROOT_PKG" | sed 's/-[0-9].*//')
        ROOT_IS_BLOCKER=0
        if [ -n "$HOLDING_BACK_PKGS" ] && [ -n "$ROOT_BASE" ]; then
            for hpkg in $HOLDING_BACK_PKGS; do
                if [ "$hpkg" = "$ROOT_BASE" ]; then ROOT_IS_BLOCKER=1; break; fi
            done
        fi

        # Header: show which problems are merged
        PNUM_LIST=$(echo $GROUP_PNUMS | sed 's/^ //; s/ /, /g')
        echo "Problem $PNUM_LIST:" >> "$ANALYSIS_LOG"
        if [ -n "$ROOT_PKG" ]; then
            ROOT_LABEL=" $ROOT_SIMPLE ($SRC_DISPLAY"
            if [ "$ROOT_IS_BLOCKER" -eq 1 ]; then
                ROOT_LABEL="$ROOT_LABEL, no update available) <-- blocker"
            else
                ROOT_LABEL="$ROOT_LABEL)"
            fi
            echo "$ROOT_LABEL" >> "$ANALYSIS_LOG"
        fi

        # Collect unique requirements across all problems in the group
        ALL_REQS=""
        for gp in $GROUP_PNUMS; do
            PREQS=$(grep "^P|${gp}|REQ|" "$TEMP_TREE_DATA" | cut -d'|' -f4)
            ALL_REQS="$ALL_REQS
$PREQS"
        done
        PROB_REQS=$(echo "$ALL_REQS" | sort -u | grep -v "^$")
        REQ_COUNT=0
        if [ -n "$PROB_REQS" ]; then
            REQ_COUNT=$(echo "$PROB_REQS" | grep -c ".")
        fi

        # Collect deduplicated conflicts across all problems in the group
        ALL_CONFLICTS=""
        for gp in $GROUP_PNUMS; do
            ALL_CONFLICTS="$ALL_CONFLICTS
$(grep "^P|${gp}|CONFLICT|" "$TEMP_TREE_DATA")"
        done
        DEDUP_CONFLICTS=$(echo "$ALL_CONFLICTS" | grep "^P|" | awk -F'|' '{
            new=$4; old=$6
            gsub(/-[0-9].*/, "", new); gsub(/-[0-9].*/, "", old)
            key = new "|" old
            if (!seen[key]++) print $0
        }')
        CONFLICT_COUNT=0
        if [ -n "$DEDUP_CONFLICTS" ]; then
            CONFLICT_COUNT=$(echo "$DEDUP_CONFLICTS" | grep -c "^P|")
        fi

        # Collect missing deps across all problems in the group
        ALL_MISSING=""
        for gp in $GROUP_PNUMS; do
            ALL_MISSING="$ALL_MISSING
$(grep "^P|${gp}|MISSING|" "$TEMP_TREE_DATA" 2>/dev/null)"
        done
        PROB_MISSING=$(echo "$ALL_MISSING" | grep "^P|" | sort -u)
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

                REQ_SIMPLIFIED=$(simplify_req "$req")
                REQ_SUFFIX=""
                if [ "$ROOT_IS_BLOCKER" -eq 1 ] && [[ "$req" == *"="* ]]; then
                    REQ_SUFFIX=" (version pin)"
                fi

                echo " $RP requires: $REQ_SIMPLIFIED$REQ_SUFFIX" >> "$ANALYSIS_LOG"

                HAS_SUMMARY=0
                if [ "$ROOT_IS_BLOCKER" -eq 1 ] && [ -n "$HELD_BACK_PKGS" ]; then
                    HAS_SUMMARY=1
                fi
                CHILD_COUNT=$(( CONFLICT_COUNT + HAS_SUMMARY ))
                CHILD_IDX=0

                if [ -n "$DEDUP_CONFLICTS" ]; then
                    while IFS='|' read -r _ _ _ new_pkg new_src old_pkg old_src; do
                        [ -z "$new_pkg" ] && continue
                        CHILD_IDX=$((CHILD_IDX + 1))
                        CP="├──"; [ "$CHILD_IDX" -eq "$CHILD_COUNT" ] && CP="└──"
                        echo " $RC $CP $(simplify_pkg "$old_pkg") ($(simplify_src "$old_src")) <-> $(simplify_pkg "$new_pkg") ($(simplify_src "$new_src")) CONFLICT" >> "$ANALYSIS_LOG"
                    done <<< "$DEDUP_CONFLICTS"
                fi

                if [ "$HAS_SUMMARY" -eq 1 ]; then
                    HELD_LIST=""
                    for hp in $HELD_BACK_PKGS; do
                        [ -n "$HELD_LIST" ] && HELD_LIST="$HELD_LIST, "
                        HELD_LIST="$HELD_LIST$hp"
                    done
                    echo " $RC └── -> $HELD_LIST held back by $ROOT_SIMPLE" >> "$ANALYSIS_LOG"
                fi
            done <<< "$PROB_REQS"
        fi

        # Show missing dependencies
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
echo "Issue type:" >> "$ANALYSIS_LOG"
echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"

# Determine the primary issue type using chain analysis
if [ "$IS_MODULAR" -eq 1 ] && ([ -s "$TEMP_CONFLICTS" ] || [ -s "$TEMP_BLOCKERS" ]); then
    ISSUE_TYPE="modular_conflict"
    echo "Type: DNF module stream conflict" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Packages from different DNF module streams are conflicting." >> "$ANALYSIS_LOG"
    if [ -s "$TEMP_MODULAR" ]; then
        echo "" >> "$ANALYSIS_LOG"
        echo "Detected modular packages:" >> "$ANALYSIS_LOG"
        sort -u "$TEMP_MODULAR" | awk '{printf "  • %s\n", $0}' >> "$ANALYSIS_LOG"
    fi
elif [ -s "$TEMP_DISTUPGRADE" ]; then
    ISSUE_TYPE="filtered_dependency_gap"
    echo "Type: Filtered update -- dependency gap" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "A filtered update (--security, --advisory, or distro-sync) needs packages" >> "$ANALYSIS_LOG"
    echo "that are NOT included in the filtered transaction scope." >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Packages outside the update scope:" >> "$ANALYSIS_LOG"
    awk -F'|' '{printf "  • %s  (%s)\n", $1, $2}' "$TEMP_DISTUPGRADE" | sort -u >> "$ANALYSIS_LOG"
elif [ -n "$HOLDING_BACK_PKGS" ] && ([ -s "$TEMP_CONFLICTS" ] || [ -s "$TEMP_BLOCKERS" ]); then
    # Genuinely installed package with no update is pinning old versions
    ISSUE_TYPE="version_pin_blocker"
    echo "Type: Version pin blocker" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "An installed package with no update is pinning old versions." >> "$ANALYSIS_LOG"
    echo "Blocker: $HOLDING_BACK_PKGS" >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_DEPD" ]; then
    ISSUE_TYPE="missing_dependency"
    echo "Type: Missing dependency" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Required packages or libraries are not available in enabled repositories." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_CONFLICTS" ] && [ -s "$TEMP_BLOCKERS" ]; then
    ISSUE_TYPE="circular_dependency"
    echo "Type: Circular dependency / version conflict" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Multiple packages have version conflicts that must resolve together." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_CONFLICTS" ]; then
    ISSUE_TYPE="version_conflict"
    echo "Type: Version conflict" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Cannot install both old and new versions simultaneously." >> "$ANALYSIS_LOG"
elif [ -s "$TEMP_BLOCKERS" ]; then
    ISSUE_TYPE="blocked_update"
    echo "Type: Blocked update" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Packages cannot be updated to their best available versions." >> "$ANALYSIS_LOG"
else
    ISSUE_TYPE="unknown"
    echo "Type: Unknown or no issues detected" >> "$ANALYSIS_LOG"
fi

# Build blocking chain for version conflicts (filtered_dependency_gap has its own chain in stdout)
if [ "$ISSUE_TYPE" = "modular_conflict" ] || [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ] || [ "$ISSUE_TYPE" = "version_pin_blocker" ]; then
    echo "" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Blocking chain:" >> "$ANALYSIS_LOG"
    echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"

    if [ -s "$TEMP_CONFLICTS" ]; then
        CONFLICT_PKGS=$(cat "$TEMP_CONFLICTS" | awk '{print $1, $3}' | tr ' ' '\n' | sed 's/-[0-9].*//' | sort -u)

        if [ -n "$HOLDING_BACK_PKGS" ]; then
            for hpkg in $HOLDING_BACK_PKGS; do
                HPKG_VER=$(grep "^$hpkg-" "$TEMP_BLOCKERS" | head -1 | sed 's/\.\(noarch\|x86_64\|i686\)$//')
                echo "Blocker: $hpkg (no update available)" >> "$ANALYSIS_LOG"
                [ -n "$HPKG_VER" ] && echo "  installed: $HPKG_VER" >> "$ANALYSIS_LOG"

                HPKG_PROBS=$(grep "^P|.*|ROOT|.*$hpkg" "$TEMP_TREE_DATA" | cut -d'|' -f2 | sort -u)
                ALL_REQS=""
                for hp in $HPKG_PROBS; do
                    PREQS=$(grep "^P|${hp}|REQ|" "$TEMP_TREE_DATA" | cut -d'|' -f4)
                    ALL_REQS="$ALL_REQS
$PREQS"
                done
                echo "$ALL_REQS" | sort -u | while IFS= read -r rq; do
                    [ -z "$rq" ] && continue
                    echo "  requires: $(simplify_req "$rq") (version pin)" >> "$ANALYSIS_LOG"
                done
            done
            echo "" >> "$ANALYSIS_LOG"

            echo "Held back:" >> "$ANALYSIS_LOG"
            for base_pkg in $CONFLICT_PKGS; do
                OLD_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')
                NEW_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')
                if [ -n "$OLD_VER" ] && [ -n "$NEW_VER" ]; then
                    echo "  $base_pkg: $OLD_VER -> $NEW_VER" >> "$ANALYSIS_LOG"
                fi
            done
            echo "" >> "$ANALYSIS_LOG"

            HELD_LIST=""
            for hp in $CONFLICT_PKGS; do
                [ -n "$HELD_LIST" ] && HELD_LIST="$HELD_LIST, "
                HELD_LIST="$HELD_LIST$hp"
            done
            BLOCKER_LIST=""
            for hp in $HOLDING_BACK_PKGS; do
                [ -n "$BLOCKER_LIST" ] && BLOCKER_LIST="$BLOCKER_LIST, "
                BLOCKER_LIST="$BLOCKER_LIST$hp"
            done

            echo "Root cause:" >> "$ANALYSIS_LOG"
            echo "  $BLOCKER_LIST has no update available and pins old versions of $HELD_LIST." >> "$ANALYSIS_LOG"
            echo "  DNF cannot update $HELD_LIST because $BLOCKER_LIST requires the old versions." >> "$ANALYSIS_LOG"
        else
            # Genuine circular dependency: all packages have updates but none can install
            for base_pkg in $CONFLICT_PKGS; do
                OLD_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')
                NEW_VER=$(grep "^$base_pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[^-]*\)\..*/\1/')

                if [ -n "$OLD_VER" ] && [ -n "$NEW_VER" ]; then
                    echo "Update attempt: $base_pkg" >> "$ANALYSIS_LOG"
                    echo "  installed: $base_pkg-$OLD_VER" >> "$ANALYSIS_LOG"
                    echo "  trying:   $base_pkg-$NEW_VER" >> "$ANALYSIS_LOG"
                    echo "  ↓ blocked: cannot install both versions simultaneously" >> "$ANALYSIS_LOG"
                    if grep -q "^$base_pkg-" "$TEMP_BLOCKERS" 2>/dev/null; then
                        echo "  ↓ reason: other packages depend on old version" >> "$ANALYSIS_LOG"
                    fi
                    echo "" >> "$ANALYSIS_LOG"
                fi
            done

            echo "Root cause:" >> "$ANALYSIS_LOG"
            echo "  All these packages form an interdependent group that must upgrade together." >> "$ANALYSIS_LOG"
            echo "  DNF cannot auto-resolve because upgrading one breaks the others." >> "$ANALYSIS_LOG"
            echo "" >> "$ANALYSIS_LOG"
            echo "Affected package group:" >> "$ANALYSIS_LOG"
            for pkg in $CONFLICT_PKGS; do
                echo "  • $pkg" >> "$ANALYSIS_LOG"
            done
        fi
    fi
fi


# Add missing dependencies section only if any were found
if [ -s "$TEMP_DEPD" ]; then
    echo "" >> "$ANALYSIS_LOG"
    echo "" >> "$ANALYSIS_LOG"
    echo "Missing dependencies:" >> "$ANALYSIS_LOG"
    echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
    cat "$TEMP_DEPD" | sort -u >> "$ANALYSIS_LOG"

    # Only query repositories if --run-queries is specified
    if [ "$RUN_QUERIES" -eq 1 ]; then
        echo "" >> "$ANALYSIS_LOG"
        echo "" >> "$ANALYSIS_LOG"
        echo "Repository analysis:" >> "$ANALYSIS_LOG"
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
        echo "Repository analysis: skipped (analysis-only mode)" >> "$ANALYSIS_LOG"
        echo "--------------------------------------------------------------------------------" >> "$ANALYSIS_LOG"
        echo "Repository queries were not run. Use --run-queries to query packages on this server." >> "$ANALYSIS_LOG"
    fi
fi

# Display summary to stdout
echo ""
echo "================================"
echo "ANALYSIS COMPLETE"
echo "================================"

# Check if any problems were found (check all temp files)
PROBLEMS_FOUND=0
PROBLEM_COUNT=0

if [ -s "$TEMP_DEPD" ] || [ -s "$TEMP_CONFLICTS" ] || [ -s "$TEMP_BLOCKERS" ] || [ -s "$TEMP_DISTUPGRADE" ]; then
    PROBLEMS_FOUND=1
fi

# Count problems from log file
if [ -f "$ANALYSIS_LOG" ]; then
    PROBLEM_COUNT=$(grep -c "^Problem [0-9]" "$ANALYSIS_LOG" 2>/dev/null)
    PROBLEM_COUNT=${PROBLEM_COUNT:-0}
fi

if [ "$PROBLEMS_FOUND" -eq 1 ]; then
    echo "Issue Type: $ISSUE_TYPE"
    echo "Found $PROBLEM_COUNT dependency problem(s)"
    echo ""

    # ================================================================
    # DEPENDENCY CHAIN DISPLAY
    # ================================================================
    # Uses NEEDS chain data to show the actual dependency flow:
    #   entry_point → intermediate → ... → root_cause (terminal failure)
    # ================================================================

    echo "Dependency chain:"
    echo "--------------------"
    echo ""

    # Helper: walk the NEEDS chain from a starting package to the endpoint
    # Outputs indented chain lines
    display_chain_from() {
        local start_pkg="$1"
        local indent="$2"
        local visited="$3"

        # Avoid infinite loops
        if echo "$visited" | grep -qw "$start_pkg" 2>/dev/null; then
            return
        fi
        visited="$visited $start_pkg"

        # Find what this package needs
        local next_pkgs=$(grep "|NEEDS|${start_pkg}|" "$TEMP_TREE_DATA" | cut -d'|' -f5 | sort -u)
        for npkg in $next_pkgs; do
            # Check what kind of terminal failure this needed package has
            local is_distupgrade=0
            local is_missing=0
            local is_conflict=0

            if [ -s "$TEMP_DISTUPGRADE" ]; then
                if awk -F'|' '{print $1}' "$TEMP_DISTUPGRADE" | sed 's/-[0-9].*//' | grep -qw "$npkg" 2>/dev/null; then
                    is_distupgrade=1
                fi
            fi
            if [ -s "$TEMP_DEPD" ]; then
                if grep -qw "$npkg" "$TEMP_DEPD" 2>/dev/null; then
                    is_missing=1
                fi
            fi
            if [ -n "$CONFLICT_PKGS_ALL" ]; then
                for cpkg in $CONFLICT_PKGS_ALL; do
                    if [ "$npkg" = "$cpkg" ]; then is_conflict=1; break; fi
                done
            fi

            # Display this link
            local suffix=""
            if [ "$is_distupgrade" -eq 1 ]; then
                suffix=" ← NOT IN UPDATE SCOPE"
            elif [ "$is_missing" -eq 1 ]; then
                suffix=" ← NOT AVAILABLE"
            elif [ "$is_conflict" -eq 1 ]; then
                suffix=" ← VERSION CONFLICT"
            fi

            # Get the requirement text for this link
            local req_text=$(grep "|NEEDS|${start_pkg}|${npkg}" "$TEMP_TREE_DATA" | head -1)
            local prob_num=$(echo "$req_text" | cut -d'|' -f2)
            local display_reqs=$(grep "^P|${prob_num}|REQ|" "$TEMP_TREE_DATA" | cut -d'|' -f4 | grep -i "$npkg" | head -1)
            if [ -z "$display_reqs" ]; then
                display_reqs="$npkg"
            else
                display_reqs=$(simplify_req "$display_reqs")
            fi

            echo "${indent}└─ needs $display_reqs${suffix}"

            # Recurse if this package also needs something
            if [ -z "$suffix" ]; then
                display_chain_from "$npkg" "${indent}   " "$visited"
            fi
        done
    }

    if [ "$ISSUE_TYPE" = "filtered_dependency_gap" ]; then
        # Show victims first, then trace to root cause
        DIST_BASE_PKGS=$(awk -F'|' '{print $1}' "$TEMP_DISTUPGRADE" | sed 's/-[0-9].*//' | sort -u)

        for vpkg in $VICTIM_PKGS; do
            echo "  $vpkg (wants to update, BLOCKED)"
            display_chain_from "$vpkg" "  " ""
        done

        # Show root cause packages that are also in blockers (they want to update too)
        for tpkg in $DIST_BASE_PKGS; do
            IS_VICTIM=0
            for v in $VICTIM_PKGS; do
                if [ "$tpkg" = "$v" ]; then IS_VICTIM=1; break; fi
            done
            if [ "$IS_VICTIM" -eq 0 ]; then
                IS_IN_BLOCKERS=0
                for b in $BLOCKER_PKGS_ALL; do
                    if [ "$tpkg" = "$b" ]; then IS_IN_BLOCKERS=1; break; fi
                done
                if [ "$IS_IN_BLOCKERS" -eq 1 ]; then
                    echo "  $tpkg (wants to update, BLOCKED)"
                    echo "    └─ NOT IN UPDATE SCOPE (--security/--advisory)"
                fi
            fi
        done
        echo ""

        if [ -s "$TEMP_CONFLICTS" ]; then
            echo "  Version conflicts (cannot coexist):"
            cat "$TEMP_CONFLICTS" | sort -u | while IFS= read -r cline; do
                echo "    • $cline"
            done
            echo ""
        fi

        DIST_LIST=$(echo $DIST_BASE_PKGS | sed 's/ /, /g')
        echo "Root cause: $DIST_LIST needs to be updated but is not included"
        echo "  in the filtered transaction (--security/--advisory/distro-sync)."
        echo ""

    elif [ "$ISSUE_TYPE" = "version_pin_blocker" ]; then
        # Genuinely installed blocker holding things back
        for hpkg in $HOLDING_BACK_PKGS; do
            echo "  $hpkg (installed, no update available) ← BLOCKER"

            HPKG_PROBS=$(grep "^P|.*|ROOT|.*$hpkg" "$TEMP_TREE_DATA" | cut -d'|' -f2 | sort -u)
            ALL_REQS=""
            for hp in $HPKG_PROBS; do
                PREQS=$(grep "^P|${hp}|REQ|" "$TEMP_TREE_DATA" | cut -d'|' -f4)
                ALL_REQS="$ALL_REQS
$PREQS"
            done
            echo "$ALL_REQS" | sort -u | while IFS= read -r rq; do
                [ -z "$rq" ] && continue
                echo "    └─ requires $(simplify_req "$rq") (version pin)"
            done
        done
        echo "  |"
        echo "  Held back:"
        if [ -n "$HELD_BACK_PKGS" ]; then
            for pkg in $HELD_BACK_PKGS; do
                OLD=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                NEW=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                if [ -n "$OLD" ] && [ -n "$NEW" ]; then
                    echo "    • $pkg: $OLD -> $NEW [BLOCKED]"
                fi
            done
        fi
        echo ""

        BLOCKER_LIST=$(echo $HOLDING_BACK_PKGS | sed 's/ /, /g')
        HELD_LIST=$(echo $HELD_BACK_PKGS | sed 's/ /, /g')
        echo "Root cause: $BLOCKER_LIST has no update and is pinning $HELD_LIST"
        echo ""

    elif [ "$ISSUE_TYPE" = "modular_conflict" ]; then
        # Use the existing modular display but with chain context
        if [ -n "$HOLDING_BACK_PKGS" ]; then
            for hpkg in $HOLDING_BACK_PKGS; do
                echo "  $hpkg (installed, no update) ← BLOCKER"
                display_chain_from "$hpkg" "  " ""
            done
            echo "  |"
            echo "  Held back:"
            for pkg in $HELD_BACK_PKGS; do
                OLD=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                NEW=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                if [ -n "$OLD" ] && [ -n "$NEW" ]; then
                    echo "    • $pkg: $OLD -> $NEW [BLOCKED]"
                fi
            done
        else
            if [ -n "$CONFLICT_PKGS_ALL" ]; then
                for pkg in $CONFLICT_PKGS_ALL; do
                    OLD=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                    NEW=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                    if [ -n "$OLD" ] && [ -n "$NEW" ]; then
                        echo "  • $pkg: $OLD -> $NEW"
                    fi
                done
            fi
        fi
        echo ""
        echo "Root cause: DNF module stream conflict"
        echo "  Packages belong to one module stream but repos have a newer stream."
        echo ""

    elif [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ]; then
        if [ -n "$CONFLICT_PKGS_ALL" ]; then
            for pkg in $CONFLICT_PKGS_ALL; do
                OLD=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $3}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                NEW=$(grep "^$pkg-" "$TEMP_CONFLICTS" | head -1 | awk '{print $1}' | sed 's/.*-\([0-9][^-]*-[0-9][^.]*\)\..*/\1/' 2>/dev/null)
                BLOCKED=""
                if echo "$BLOCKER_PKGS_ALL" | grep -qw "$pkg" 2>/dev/null; then
                    BLOCKED=" [HELD BACK]"
                fi
                echo "  • $pkg: $OLD -> $NEW$BLOCKED"
                display_chain_from "$pkg" "  " ""
            done
        fi
        echo ""
        echo "Root cause: Version conflict -- packages must upgrade together"
        echo ""

    elif [ "$ISSUE_TYPE" = "missing_dependency" ]; then
        # Show what's missing and who needs it
        if [ -s "$TEMP_DEPD" ]; then
            cat "$TEMP_DEPD" | sort -u | while IFS= read -r dep; do
                echo "  MISSING: $dep"
            done
            echo "  |"
            AFFECTED=$(cat "$TEMP_FAILPKG" | grep -v "^--$" | grep -v "^$" | sed 's/-[0-9].*//' | sort -u)
            for apkg in $AFFECTED; do
                echo "  └─ blocks: $apkg"
            done
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

        if [ -n "$HOLDING_BACK_PKGS" ]; then
            echo "Option 1 (RECOMMENDED): Remove the blocker package, then update"
            echo "----------------------------------------------------------------"
            echo "  # $HOLDING_BACK_PKGS has no update -- removing it unblocks $(echo $HELD_BACK_PKGS | tr ' ' '\n' | paste -sd', ')"
            for pkg in $HOLDING_BACK_PKGS; do
                echo "  dnf remove $pkg"
            done
            echo "  dnf update"
            echo ""

            echo "Option 2: Reset module stream and retry update"
            echo "-----------------------------------------------"
            for pkg in $MODULE_PKGS; do
                echo "  dnf module reset $pkg"
            done
            echo "  dnf update"
            echo ""

            echo "Option 3: Force update with --allowerasing"
            echo "--------------------------------------------"
            echo "  dnf update --allowerasing $MODULE_PKGS"
            echo "  (CAUTION: Review what will be removed before confirming)"
            echo ""
        else
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
        fi

    elif [ "$ISSUE_TYPE" = "circular_dependency" ] || [ "$ISSUE_TYPE" = "version_conflict" ] || [ "$ISSUE_TYPE" = "version_pin_blocker" ]; then
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
        if [ -n "$HOLDING_BACK_PKGS" ]; then
            for pkg in $HOLDING_BACK_PKGS; do
                echo "rpm -q --whatrequires $pkg"
                echo "yum list --showduplicates $pkg"
            done
        elif [ -s "$TEMP_BLOCKERS" ]; then
            BLOCKER_PKGS=$(cat "$TEMP_BLOCKERS" | sed 's/-[0-9].*//' | sort -u | head -3)
            for pkg in $BLOCKER_PKGS; do
                echo "rpm -q --whatrequires $pkg"
            done
        fi
        echo ""

        echo "================================"
        echo "POSSIBLE SOLUTIONS"
        echo "================================"
        echo ""

        if [ -n "$HOLDING_BACK_PKGS" ]; then
            echo "Option 1 (RECOMMENDED): Remove the blocker package, then update"
            echo "----------------------------------------------------------------"
            echo "  # $HOLDING_BACK_PKGS has no update -- removing it unblocks the rest"
            for pkg in $HOLDING_BACK_PKGS; do
                echo "  dnf remove $pkg"
            done
            echo "  dnf update"
            echo ""

            echo "Option 2: Force update with --allowerasing"
            echo "--------------------------------------------"
            echo "  dnf update --allowerasing $CONFLICT_PKGS"
            echo "  (CAUTION: Review what will be removed before confirming)"
            echo ""
        else
            echo "IF no excludes found (Step 1) AND packages available (Step 2):"
            echo "  -> Try coordinated update of entire group:"
            echo "    dnf update $CONFLICT_PKGS"
            echo ""
            echo "IF that fails with conflicts:"
            echo "  -> Use allowerasing (CAUTION: review what will be removed):"
            echo "    dnf update --allowerasing $CONFLICT_PKGS"
            echo ""
            echo "IF excludes ARE found in Step 1:"
            echo "  -> Remove exclude from config OR use:"
            echo "    dnf update --disableexcludes=all $CONFLICT_PKGS"
            echo ""
        fi

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

    elif [ "$ISSUE_TYPE" = "filtered_dependency_gap" ]; then
        DIST_BASE_PKGS=$(awk -F'|' '{print $1}' "$TEMP_DISTUPGRADE" | sed 's/-[0-9].*//' | sort -u)
        DIST_FULL_PKGS=$(awk -F'|' '{print $1}' "$TEMP_DISTUPGRADE" | sort -u | tr '\n' ' ')
        BLOCKED_PKGS=""
        if [ -s "$TEMP_BLOCKERS" ]; then
            BLOCKED_PKGS=$(cat "$TEMP_BLOCKERS" | sed 's/-[0-9].*//' | sort -u | tr '\n' ' ')
        fi

        echo "STEP 1: Confirm whether --security or --advisory was used"
        echo "-----------------------------------------------------------"
        echo "dnf history info last"
        echo "# Look for 'Command Line' to see if --security/--advisory was passed"
        echo ""

        echo "STEP 2: Check if the dependency packages have updates available"
        echo "----------------------------------------------------------------"
        for dpkg in $DIST_BASE_PKGS; do
            echo "yum list --showduplicates $dpkg"
        done
        echo ""

        echo "STEP 3: Check for advisories on the dependency packages"
        echo "--------------------------------------------------------"
        for dpkg in $DIST_BASE_PKGS; do
            echo "dnf updateinfo list --installed $dpkg"
        done
        echo ""

        echo "================================"
        echo "POSSIBLE SOLUTIONS"
        echo "================================"
        echo ""

        DIST_LIST=$(echo $DIST_BASE_PKGS | tr ' ' ', ')

        echo "Option 1 (RECOMMENDED): Update the dependency packages first, then retry"
        echo "--------------------------------------------------------------------------"
        echo "  yum update $DIST_BASE_PKGS"
        echo "  yum update --security"
        echo ""

        echo "Option 2: Run a full update instead of filtered"
        echo "-------------------------------------------------"
        echo "  yum update"
        echo "  # This pulls in all available updates including dependencies"
        echo ""

        I686_PKGS=$(awk -F'|' '/\.i686/{print $1}' "$TEMP_DISTUPGRADE" | sed 's/-[0-9].*/.i686/' | sort -u | tr '\n' ' ')
        if [ -n "$I686_PKGS" ]; then
            echo "Option 3: Remove unneeded multilib (i686) packages"
            echo "----------------------------------------------------"
            echo "  dnf remove $I686_PKGS"
            echo "  # Then retry: yum update --security"
            echo ""
        fi
    fi
else
    echo "No dependency problems found in $LOGFILE"
    echo ""
    echo "The log file may not contain dependency errors, or they are already resolved."
fi

echo ""
echo "================================"
echo "Full analysis saved to: $ANALYSIS_LOG"
echo "================================"
echo ""

# Clean up all temporary files (ensure cleanup happens regardless of errors)
rm -f "$TEMP_FAILPKG" "$TEMP_DEPD" "$TEMP_CONFLICTS" "$TEMP_BLOCKERS" "$TEMP_OBSOLETES" "$TEMP_MODULAR" "$TEMP_DISTUPGRADE" "$TEMP_TREE_DATA" 2>/dev/null
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
