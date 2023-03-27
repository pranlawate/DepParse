#!/bin/bash
echo "-----------------------"
echo "Parsing the yumlog.txt"
echo "-----------------------"
echo '' > failpkg.prn
:>| depd.prn

while read line; do
   awk '/problem with installed package/{print $NF}' <<< $line >> failpkg.prn;
#### Add 'requires' parsing , package A requires B; then B needs <package/obj> , add it to the depd.prn
#
#  if [[ "$line" = *requires* ]]; then
#
#       awk '/requires/{print $2" --> "$4"-"$6"}' <<< "$line" 
#
#  fi
   if [[ "$line" = *nothing" "provides* ]]; then
#   	echo $line
   #   Adding the higher version of the package which failed to install
	awk '/nothing provides/{print $NF}' <<< "$line" >> failpkg.prn
	echo '--' >> failpkg.prn 
   #
   #
   #### Need to collect the nothing provides <package/obj> and then pass it to depd.prn and then to yum list.
        awk '{print $4}' <<< "$line" >> depd.prn
   #
   #	awk -F"=" '/needed by/{print "^^ needs" $1 $2}' <<< $line >> failpkg.prn 
   #     yum list $(yum whatprovides $(cat depd.prn) | grep -EV "^Repo|^Matched|^Provide")
   fi
done < yumlog.txt
  echo "-------" 
  echo "Failed packages list"
  echo ""
  #  echo "`cat failpkg.prn`"
  echo "`cat failpkg.prn | awk 'BEGIN {RS="--"; FS="\n";} { print $2 "\t\tfails update because\t" $3 "\t\tdoesnt have deps fullfilled";}'`"
  echo "=========="

if [ -f depd.prn ]
then
    if  [ -s depd.prn ]
    then
        echo ""
        echo "Failed dependencies:>"
        echo ""
        echo "`cat depd.prn | sort -u`"
        echo "====================="
        echo "Runnnig yum list for the missing deps"
        echo ""
#       yum list $(yum whatprovides $(cat depd.prn | sort -u) | awk -F. '/.el8./{print $1}' | awk 'BEGIN{FS=OFS="-"}{NF--;print}'| grep -v 'Provide'| sort -u) 
# I modified /.el8./ to /.el8/ since it's loosing el8_5 and similar ones.
# I also plan to add egrep to loose lines with 'Repo,Matched, Provide and Filename
# I have found filename parser that works better than <awk 'BEGIN{FS=OFS="-"}{NF--;print}'> 
	yum list $(yum whatprovides $(cat depd.prn | sort -u) | egrep -v "^Repo|^Matched|^Provide|^Filename" | awk -F. '/.el8/{print $1}' | sed 's:-[0-9].*::'  | sort -u)
    else 
        echo "No Deps failed, file empty" 
    fi
else 
    echo "File doesn't exist"  
fi
