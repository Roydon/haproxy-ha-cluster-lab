// Demo endpoint: proves the app tier is load-balanced (varying hostname) and that it
// can reach both databases *through HAProxy*, not directly.
const express = require('express');
const os = require('os');
const { Client: PgClient } = require('pg');
const mysql = require('mysql2/promise');

const app = express();
const PORT = 8080;

app.get('/health', (_req, res) => res.status(200).send('ok\n'));

app.get('/', async (_req, res) => {
  const hostname = os.hostname();
  const result = { hostname, backend: 'node+express' };

  try {
    const pg = new PgClient({
      host: process.env.PG_HOST || 'haproxy',
      port: Number(process.env.PG_WRITE_PORT || 5000),
      database: process.env.POSTGRES_APP_DB || 'appdb',
      user: process.env.POSTGRES_APP_USER || 'appuser',
      password: process.env.POSTGRES_APP_PASSWORD || 'appuser_lab_pw',
      connectionTimeoutMillis: 3000,
    });
    await pg.connect();
    await pg.query(
      'CREATE TABLE IF NOT EXISTS app_pings (id SERIAL PRIMARY KEY, source TEXT, seen_at TIMESTAMPTZ DEFAULT now())'
    );
    await pg.query('INSERT INTO app_pings (source) VALUES ($1)', [hostname]);
    const { rows } = await pg.query('SELECT count(*) FROM app_pings');
    result.postgres = { ok: true, ping_count: Number(rows[0].count) };
    await pg.end();
  } catch (e) {
    result.postgres = { ok: false, error: e.message };
  }

  try {
    const conn = await mysql.createConnection({
      host: process.env.MYSQL_HOST || 'haproxy',
      port: Number(process.env.MYSQL_WRITE_PORT || 3307),
      database: process.env.MYSQL_APP_DB || 'appdb',
      user: process.env.MYSQL_APP_USER || 'appuser',
      password: process.env.MYSQL_APP_PASSWORD || 'appuser_lab_pw',
      connectTimeout: 3000,
    });
    await conn.execute(
      'CREATE TABLE IF NOT EXISTS app_pings (id INT PRIMARY KEY AUTO_INCREMENT, source VARCHAR(255), seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'
    );
    await conn.execute('INSERT INTO app_pings (source) VALUES (?)', [hostname]);
    const [rows] = await conn.execute('SELECT count(*) as c FROM app_pings');
    result.mysql = { ok: true, ping_count: Number(rows[0].c) };
    await conn.end();
  } catch (e) {
    result.mysql = { ok: false, error: e.message };
  }

  res.json(result);
});

app.listen(PORT, () => console.log(`node app listening on :${PORT}`));
