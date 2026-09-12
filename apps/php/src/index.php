<?php
// Demo endpoint: proves the app tier is load-balanced (varying hostname) and that it
// can reach both databases *through HAProxy*, not directly -- PG_HOST/MYSQL_HOST below
// point at the haproxy service, not at a specific db node.
header('Content-Type: application/json');

$hostname = gethostname();
$result = ['hostname' => $hostname, 'backend' => 'php-fpm+nginx'];

try {
    $pgHost = getenv('PG_HOST') ?: 'haproxy';
    $pgWritePort = getenv('PG_WRITE_PORT') ?: '5000';
    $dsn = "pgsql:host=$pgHost;port=$pgWritePort;dbname=" . (getenv('POSTGRES_APP_DB') ?: 'appdb');
    $pdo = new PDO($dsn, getenv('POSTGRES_APP_USER') ?: 'appuser', getenv('POSTGRES_APP_PASSWORD') ?: 'appuser_lab_pw', [
        PDO::ATTR_TIMEOUT => 3,
    ]);
    $pdo->exec("CREATE TABLE IF NOT EXISTS app_pings (id SERIAL PRIMARY KEY, source TEXT, seen_at TIMESTAMPTZ DEFAULT now())");
    $pdo->exec("INSERT INTO app_pings (source) VALUES ('$hostname')");
    $count = $pdo->query("SELECT count(*) FROM app_pings")->fetchColumn();
    $result['postgres'] = ['ok' => true, 'ping_count' => (int) $count];
} catch (Throwable $e) {
    $result['postgres'] = ['ok' => false, 'error' => $e->getMessage()];
}

try {
    $mysqlHost = getenv('MYSQL_HOST') ?: 'haproxy';
    $mysqlWritePort = getenv('MYSQL_WRITE_PORT') ?: '3307';
    $dsn = "mysql:host=$mysqlHost;port=$mysqlWritePort;dbname=" . (getenv('MYSQL_APP_DB') ?: 'appdb');
    $pdo = new PDO($dsn, getenv('MYSQL_APP_USER') ?: 'appuser', getenv('MYSQL_APP_PASSWORD') ?: 'appuser_lab_pw', [
        PDO::ATTR_TIMEOUT => 3,
    ]);
    $pdo->exec("CREATE TABLE IF NOT EXISTS app_pings (id INT PRIMARY KEY AUTO_INCREMENT, source VARCHAR(255), seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)");
    $pdo->exec("INSERT INTO app_pings (source) VALUES ('$hostname')");
    $count = $pdo->query("SELECT count(*) FROM app_pings")->fetchColumn();
    $result['mysql'] = ['ok' => true, 'ping_count' => (int) $count];
} catch (Throwable $e) {
    $result['mysql'] = ['ok' => false, 'error' => $e->getMessage()];
}

echo json_encode($result, JSON_PRETTY_PRINT) . "\n";
