#!/usr/bin/env bash

SKYPE_ROOT="$HOME/Library/Application Support/Skype"
if [ $# -eq 0 ] ; then
  echo "usage skype_id [filename]" >&2
  echo "use stdout for standard out"
  echo
  echo "possibilities:"
  #TODO: use the id if there is only one?
  for x in $(cd "${SKYPE_ROOT}" ; ls */main.db) ; do
    x=${x%/main.db}
    echo "  $x"
  done

  exit 1
fi

name=$1
file=${2-stdout}

sqlite3 -batch "${SKYPE_ROOT}/${name}/main.db" <<EOF
.mode csv
.output ${file}
select skypename,pstnnumber,aliases,fullname,emails, phone_home, phone_office, province, city
from Contacts
where is_permanent=1 and coalesce(isblocked,0) <>1;
.output stdout
.exit
EOF

# "/Users/kbrock/Library/Application Support/Skype/keenan_brock/main.db"

# ADDRESS_BOOK=$HOME/Library/Application\ Support/AddressBook/AddressBook-v22.abcddb
# sqlite3 --batch "${ADDRESS_BOOK}" <<EOF
# select e.ZADDRESSNORMALIZED,p.ZFIRSTNAME,p.ZLASTNAME,p.ZORGANIZATION
# from ZABCDRECORD as p join ZABCDEMAILADDRESS as e on e.ZOWNER = p.Z_PK;
# EOF

