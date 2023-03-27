# DepParse
I intend to create a parser for yum/dnf package dependency error log in RHEL 8 format


tl;dr:
1. Add your complete dependency error into yumlog.txt kept in the same directory as yumlooper.sh (Example added) 
2. Run yumlooper.sh 
3. It shall create 2 files `failpkg.prn` and `depd.prn`
4. failpkg.prn (For now) lists the higher version of the package which got failed to install
5. depd.prn collects the `nothing provides <package/obj>` 

*Note*: Currently This parser only parses dependency stack with 'nothing provides <package = version>/<obj>.so(XYZ) needed by <package that fails>
