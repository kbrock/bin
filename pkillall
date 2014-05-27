#!/usr/bin/env bash

# kill all connections to the postgres server

dbname=$1

if [ -n "$1" ] ; then
  where="where pg_stat_activity.datname = '$1'"
  echo "killing all connections to database '$1'"
else
  echo "killing all connections to database"
fi

#some postgresses call it procid, others pid
cat <<-EOF | psql -U ${PGUSER:-postgres} -d postgres -h ${PGHOST:-localhost}
SELECT pg_terminate_backend(pg_stat_activity.pid)
FROM pg_stat_activity
${where}
EOF
