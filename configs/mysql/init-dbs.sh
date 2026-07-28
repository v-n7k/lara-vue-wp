docker_process_sql <<-SQL
    CREATE DATABASE IF NOT EXISTS \`wordpress\`;
    GRANT ALL ON \`wordpress\`.* TO '$MYSQL_USER'@'%';
SQL