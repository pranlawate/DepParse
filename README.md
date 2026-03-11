# DepParse
A comprehensive toolkit for analyzing package dependency issues and version mismatches in RHEL 8/9 systems.

## Tools Included

### 1. yumlooper.sh - DNF/YUM Dependency Analyzer
Parses complete dependency chains from `dnf`/`yum` error logs and provides actionable fix recommendations.

### 2. cleanup_analyzer.sh - Package Version Mismatch Detector (NEW!)
Analyzes `package-cleanup --problems` output to identify version mismatches and partial update issues.

### 3. investigate_blockers.sh - Package Upgrade Blocker Detective
Investigates why specific packages cannot be upgraded.

## Features
- ✅ **True root cause identification** - distinguishes blocker packages (no update) from held-back packages (have updates)
- ✅ **Visual dependency tree** - per-problem tree with blocker labels, version pins, and cause-effect summary
- ✅ **Modular conflict detection** - identifies RHEL 8/9 DNF module stream conflicts
- ✅ Parses complete dependency chains including "requires" relationships
- ✅ Identifies root cause missing dependencies and blocked providers
- ✅ **Detects version conflicts** (`cannot install both`) and blocked updates
- ✅ **Detects version mismatches** between packages and subpackages
- ✅ **Analyzes partial update scenarios** (interrupted transactions, mixed versions)
- ✅ Prioritized troubleshooting - recommends removing the true blocker first
- ✅ Organizes output by problem number for easy navigation
- ✅ Optional repository queries with `--run-queries` flag
- ✅ **Single comprehensive log file** - all analysis in one place
- ✅ Clean stdout summary with issue type, blocking chain, and troubleshooting steps

## Quick Start

1. Get the dependency error from the customer system:
   ```bash
   dnf update 2>&1 | tee yumlog.txt
   ```
2. Place the `yumlog.txt` in the same directory as `yumlooper.sh` and run:
   ```bash
   ./yumlooper.sh
   ```
3. Review the analysis, send the troubleshooting commands to the customer, and iterate

## Usage

```bash
./yumlooper.sh              # Analysis only (default) - shows issue type + troubleshooting steps
./yumlooper.sh --run-queries  # Also queries yum/dnf repos on THIS server
./yumlooper.sh -v           # Verbose mode (reserved for future use)
./yumlooper.sh --help       # Show help
```

## Output

### Standard Output (stdout)
Shows the issue type, blocking chain with true blocker identification, and prioritized troubleshooting:
```
================================
ANALYSIS COMPLETE
================================
Issue Type: modular_conflict
Found 2 dependency problem(s)

BLOCKING CHAIN:
--------------------

TRUE BLOCKER: ant-javamail (no update available)
  requires ant = 1.10.5 (pinned)
  requires mvn(org.apache.ant:ant) = 1.10.5 (pinned)
  |
HELD BACK:
  • ant: 1.10.5-1 -> 1.10.9-1 [BLOCKED]
  • ant-lib: 1.10.5-1 -> 1.10.9-1 [BLOCKED]

ROOT CAUSE: ant-javamail has no update and is holding back ant, ant-lib

================================
POSSIBLE SOLUTIONS
================================

Option 1 (RECOMMENDED): Remove the blocker package, then update
  # ant-javamail has no update -- removing it unblocks ant, ant-lib
  dnf remove ant-javamail
  dnf update
...
```

### Analysis Log File: `depparse_analysis.log`
A single comprehensive file containing:

1. **DEPENDENCY TREE** - Visual per-problem tree identifying blockers and held-back packages
   ```
   Problem 1:
    ant-javamail-1.10.5 (installed, NO UPDATE AVAILABLE) <-- BLOCKER
    └── requires: ant = 1.10.5 (version pin)
         ├── ant-1.10.5 (installed) <-> ant-1.10.9 (appstream) CONFLICT
         └── -> ant, ant-lib held back by ant-javamail-1.10.5

   Problem 2:
    ant-javamail-1.10.5 (codeready-builder + installed, NO UPDATE AVAILABLE) <-- BLOCKER
    └── requires: mvn(org.apache.ant:ant) = 1.10.5 (version pin)
         ├── ant-lib-1.10.5 (installed) <-> ant-lib-1.10.9 (appstream) CONFLICT
         └── -> ant, ant-lib held back by ant-javamail-1.10.5
   ```

2. **ISSUE TYPE ANALYSIS** - Detected issue classification (modular conflict, circular dependency, version conflict, missing dependency, blocked update)

3. **BLOCKING CHAIN ANALYSIS** - Identifies true blockers (no update available) vs held-back packages (have updates), with root cause explanation

4. **VERSION CONFLICTS / BLOCKED UPDATES** - Raw conflict and blocker data

5. **REPOSITORY ANALYSIS** (with `--run-queries`) - Available packages from enabled repos

To view the full analysis:
```bash
cat depparse_analysis.log
# or
less depparse_analysis.log
```

## What It Parses

- `problem with installed package` - Identifies problematic packages
- `nothing provides <dependency>` - Root cause missing dependencies
- `but none of the providers can be installed` - Blocked dependency providers
- `package X requires Y` - Dependency chain relationships
- `cannot install both X and Y` - Version conflicts between old and new packages
- `cannot install the best update candidate` - Blocked package updates
- `obsoletes` - Package replacement relationships
- `module+el` version strings - DNF module stream conflicts (RHEL 8/9)
- Repository queries via `yum whatprovides` (with `--run-queries`) - Available package versions

## Package Version Mismatch Analysis (cleanup_analyzer.sh)

### When to Use
When you encounter:
- DNF segfaults during transaction check
- 100s or 1000s of `package-cleanup --problems`
- Version mismatches between packages and their subpackages
- System showing signs of interrupted/partial updates

### Quick Start
```bash
# Get the problems
package-cleanup --problems > cleanup_problems.txt

# Analyze them
./cleanup_analyzer.sh cleanup_problems.txt

# Review the report
cat cleanup_analysis.log
```

### Output
The tool identifies:
- **Critical packages** with version mismatches (rpm, glibc, systemd, etc.)
- **Package families** with split versions
- **Root cause** of the version chaos
- **Recommended fix strategy** with exact commands

Example output:
```
CRITICAL: The following core packages are affected:
  • rpm
  • systemd
  • glibc

==== OPTION 1: Nuclear Reinstall (RECOMMENDED) ====
# Download and force-reinstall core packages
mkdir -p /tmp/recovery
dnf download --destdir=/tmp/recovery rpm rpm-libs systemd systemd-libs...
rpm -Uvh --force --nodeps /tmp/recovery/glibc*.rpm
...
```

### Real-World Scenario
This tool was created to handle a system with **948 package problems** causing DNF to segfault. The analysis identified:
- RPM version mismatch (rpm-4.16.1.3-29 vs python3-rpm-4.16.1.3-37)
- Multiple glibc versions installed simultaneously
- Systemd split between 252-32 and 252-51
- Cascading failures in 100+ packages

## Why One Log File?

- **Simpler** - Everything in one place, no juggling multiple files
- **Complete** - Full context and analysis together
- **Portable** - Easy to share the entire analysis
- **Clean stdout** - Shows only what you need to act on immediately
