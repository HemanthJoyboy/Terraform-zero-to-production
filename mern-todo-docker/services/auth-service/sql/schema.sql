-- Runs automatically the FIRST time the postgres container initializes an
-- empty data volume (mounted into /docker-entrypoint-initdb.d - see
-- docker-compose.yml / README Section 5). To run it by hand instead:
--   docker exec -it postgres psql -U todo -d tododb -f /docker-entrypoint-initdb.d/01-auth.sql
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(150) UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
