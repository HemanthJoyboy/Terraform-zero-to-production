-- Runs automatically the FIRST time the postgres container initializes an
-- empty data volume (mounted into /docker-entrypoint-initdb.d - see
-- docker-compose.yml / README Section 5). To run it by hand instead:
--   docker exec -it postgres psql -U todo -d tododb -f /docker-entrypoint-initdb.d/02-todo.sql
CREATE TABLE IF NOT EXISTS todos (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL,
  title VARCHAR(255) NOT NULL,
  is_done BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);
