# Compte Debezium (ADR 0037, DE33). Source par run-mysqld a chaque demarrage, volume existant compris :
# root local par socket, sans mot de passe root. Sans secret, rien n'est fait : MySQL demarre normalement.
if [ -z "${DEBEZIUM_DB_PASSWORD:-}" ]; then
  log_info 'Compte debezium : aucun mot de passe fourni, etape ignoree'
  return 0
fi

log_info 'Compte debezium : creation ou mise a jour'
mysql $admin_flags <<SQL
CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED BY '${DEBEZIUM_DB_PASSWORD}';
ALTER USER 'debezium'@'%' IDENTIFIED BY '${DEBEZIUM_DB_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
GRANT SELECT ON \`${MYSQL_DATABASE}\`.* TO 'debezium'@'%';
SQL
