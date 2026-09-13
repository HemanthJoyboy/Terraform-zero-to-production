import pg from 'pg';
import dotenv from 'dotenv';
dotenv.config();

const { Pool } = pg;

// DATABASE_URL comes from .env -> points at the local `postgres` container,
// e.g. postgres://todo:todo@postgres:5432/tododb
// No SSL here: the connection to the postgres container stays inside the
// Docker network, so there's no Neon-style "SSL required" step.
export const pool = new Pool({
  connectionString: process.env.DATABASE_URL
});
