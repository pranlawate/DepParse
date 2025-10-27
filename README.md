# DepParse
A comprehensive parser for yum/dnf package dependency error logs in RHEL 8/9 format that analyzes dependency chains and provides actionable fix recommendations.

## Features
- ✅ Parses complete dependency chains including "requires" relationships
- ✅ Identifies root cause missing dependencies
- ✅ Provides exact installation commands to resolve issues
- ✅ Organizes output by problem number for easy navigation
- ✅ Queries repositories to find available package versions
- ✅ **Single comprehensive log file** - all analysis in one place
- ✅ Clean stdout summary with quick fix commands

## Quick Start

1. Add your complete dependency error into `yumlog.txt` in the same directory as `yumlooper.sh` (Example included)
2. Run the script:
   ```bash
   ./yumlooper.sh
   ```
3. See the fix command in the output and run it, or review the full analysis in the log file

## Usage

```bash
./yumlooper.sh              # Standard analysis
./yumlooper.sh -v           # Verbose mode (for future debugging features)
./yumlooper.sh --help       # Show help
```

## Output

### Standard Output (stdout)
Shows a clean summary with the most important information:
```
================================
ANALYSIS COMPLETE
================================

Missing Dependencies:
--------------------
  • platform-python-pip
  • libjansson.so.4(libjansson.so.4)(64bit)
  • libjson-c.so.4(JSONC_0.14)(64bit)

RECOMMENDED FIX:
================
yum install jansson json-c platform-python-pip

Full analysis saved to: depparse_analysis.log
```

### Analysis Log File: `depparse_analysis.log`
A single comprehensive file containing:

1. **DETAILED DEPENDENCY CHAINS** - Tree-structured view of all problems
   ```
   === Problem 1 ===
   Installed: python3-pip-9.0.3-20.el8.noarch
     \-- MISSING: platform-python-pip = 9.0.3-22.el8
         (needed by: python3-pip-9.0.3-22.el8.noarch)
   ```

2. **FAILED PACKAGES SUMMARY** - Which packages failed and why

3. **ROOT CAUSE - MISSING DEPENDENCIES** - List of missing dependencies

4. **REPOSITORY ANALYSIS** - Available packages from enabled repos

5. **RECOMMENDED FIXES** - Exact commands to fix the issues
   ```
   To fix the dependency issues, install/update these packages:

     • jansson-2.14-1.el8 (from rhel-8-for-x86_64-baseos-rpms)
     • json-c-0.13.1-3.el8 (from rhel-8-for-x86_64-baseos-rpms)
     • platform-python-pip-9.0.3-24.el8 (from rhel-8-for-x86_64-baseos-rpms)

   Installation commands:
   ---------------------
   yum install jansson json-c platform-python-pip

   # Or to update:
   yum update jansson json-c platform-python-pip
   ```

To view the full analysis:
```bash
cat depparse_analysis.log
# or
less depparse_analysis.log
```

## What It Parses

- `problem with installed package` - Identifies problematic packages
- `nothing provides <dependency>` - Root cause missing dependencies
- `package X requires Y` - Dependency chain relationships
- Repository queries via `yum whatprovides` - Available package versions

## Why One Log File?

- **Simpler** - Everything in one place, no juggling multiple files
- **Complete** - Full context and analysis together
- **Portable** - Easy to share the entire analysis
- **Clean stdout** - Shows only what you need to act on immediately
