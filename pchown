#!/bin/bash

# references: http://stackoverflow.com/questions/1348126/modify-owner-on-all-tables-simultaneously-in-postgresql
function usage() {
  echo "usage: $(basename $0) [-u username] [dbname]" >&2
  echo "    changes ownership of all objects in a database to a particular user" >&2
  echo "    -u user to own database [default: ${PGUSER}]" >&2
  echo "    [dbname] is the database to change [default: ${PGDATABASE-MISSING}]" >&2
  exit 1
}

# default values

while getopts "hu:" opt ; do
  case $opt in
    h) usage ;;
    u) PGUSER=$OPTARG ;;
    \?) echo "Invalid option: -$OPTARG" >&2 ;;
  esac
done
shift $((OPTIND-1))

if [[ $# -gt 0 ]] ; then
  PGDATABASE="$1"
fi

if [[ -z "${PGDATABASE}" || -z "${PGUSER}" ]] ; then
  usage
fi

export PGDATABASE PGUSER

psql << SQL
DO \$\$DECLARE r record;
DECLARE
    v_schema varchar := 'public';
    v_new_owner varchar := '${PGUSER}';
BEGIN
    FOR r IN 
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.tables where table_schema = v_schema
        union all
        select 'ALTER TABLE "' || sequence_schema || '"."' || sequence_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.sequences where sequence_schema = v_schema
        union all
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.views where table_schema = v_schema
        union all
        select 'ALTER FUNCTION "'||nsp.nspname||'"."'||p.proname||'"('||pg_get_function_identity_arguments(p.oid)||') OWNER TO ' || v_new_owner || ';' as a from pg_proc p join pg_namespace nsp ON p.pronamespace = nsp.oid where nsp.nspname = v_schema
        union all
        select 'ALTER SCHEMA "' || v_schema || '" OWNER TO ' || v_new_owner 
        union all
        select 'ALTER DATABASE "' || current_database() || '" OWNER TO ' || v_new_owner 
    LOOP
        EXECUTE r.a;
    END LOOP;
END\$\$;
SQL
