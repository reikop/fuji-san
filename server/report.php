<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
security_headers();
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') respond(200, ['service'=>'fuji-san-reports', 'schema'=>1, 'retentionDays'=>30]);
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') { header('Allow: GET, POST'); respond(405, ['error'=>'method_not_allowed']); }
try {
    if (strtolower(trim(explode(';', $_SERVER['CONTENT_TYPE'] ?? '')[0])) !== 'application/json') respond(415, ['error'=>'json_required']);
    if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_REPORT_BYTES) respond(413, ['error'=>'too_large']);
    clean_expired();
    if (!rate_limit('submit', 20, 3600)) { header('Retry-After: 3600'); respond(429, ['error'=>'rate_limited']); }
    $raw = file_get_contents('php://input', false, null, 0, MAX_REPORT_BYTES + 1);
    if ($raw === false || strlen($raw) > MAX_REPORT_BYTES) respond(413, ['error'=>'too_large']);
    $data = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
    if (!is_array($data)) respond(400, ['error'=>'invalid_report']);
    $report = validate_report($data);
    $path = storage() . '/report-' . $report['id'] . '.php';
    $lock = fopen(storage() . '/submit-lock.php', 'c+');
    if (!$lock || !flock($lock, LOCK_EX)) throw new RuntimeException('Storage busy');
    try {
        $duplicate = file_exists($path);
        if (!$duplicate) {
            if (count(glob(storage() . '/report-*.php') ?: []) >= 2000) respond(503, ['error'=>'storage_full']);
            write_data($path, $report);
        }
    } finally { flock($lock, LOCK_UN); fclose($lock); }
    respond($duplicate ? 200 : 201, ['id'=>$report['id'], 'received'=>true]);
} catch (JsonException|InvalidArgumentException $e) {
    respond(400, ['error'=>'invalid_report']);
} catch (Throwable $e) {
    error_log('Fuji San report service failed: ' . get_class($e));
    respond(503, ['error'=>'temporarily_unavailable']);
}
