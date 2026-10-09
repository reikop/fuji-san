<?php
declare(strict_types=1);
ini_set('display_errors', '0');
const DATA_GUARD = "<?php http_response_code(404); exit; __halt_compiler();\n";
const MAX_REPORT_BYTES = 262144;
function config(): array {
    static $config;
    if ($config === null) $config = require __DIR__ . '/config.php';
    return $config;
}
function security_headers(): void {
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');
    header("Content-Security-Policy: default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
}
function respond(int $code, array $data): never {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}
function storage(): string {
    $path = __DIR__ . '/private';
    if (!is_dir($path) && !mkdir($path, 0700, true)) throw new RuntimeException('Storage unavailable');
    return $path;
}
function read_data(string $path): array {
    $raw = file_get_contents($path);
    if ($raw === false || !str_starts_with($raw, DATA_GUARD)) throw new RuntimeException('Invalid storage');
    return json_decode(substr($raw, strlen(DATA_GUARD)), true, 32, JSON_THROW_ON_ERROR);
}
function write_data(string $path, array $data): void {
    $bytes = DATA_GUARD . json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    $temp = $path . '.' . bin2hex(random_bytes(8)) . '.php';
    if (file_put_contents($temp, $bytes, LOCK_EX) !== strlen($bytes)) {
        @unlink($temp);
        throw new RuntimeException('Storage write failed');
    }
    chmod($temp, 0600);
    if (!rename($temp, $path)) { @unlink($temp); throw new RuntimeException('Storage rename failed'); }
}
// The reverse proxy's forwarding headers are not trusted as rate-limit identities.
// Only an HMAC of REMOTE_ADDR is retained, never the raw address.
function rate_limit(string $bucket, int $limit, int $window): bool {
    $key = hash_hmac('sha256', $bucket . ':' . ($_SERVER['REMOTE_ADDR'] ?? 'unknown'), config()['rate_secret']);
    $path = storage() . '/rate-' . $key . '.php';
    $file = fopen($path, 'c+');
    if (!$file || !flock($file, LOCK_EX)) throw new RuntimeException('Rate limiter unavailable');
    try {
        $raw = stream_get_contents($file);
        $state = str_starts_with($raw, DATA_GUARD) ? json_decode(substr($raw, strlen(DATA_GUARD)), true) : null;
        if (!is_array($state) || ($state['until'] ?? 0) <= time()) $state = ['until'=>time() + $window, 'count'=>0];
        $allowed = $state['count'] < $limit;
        if ($allowed) $state['count']++;
        $bytes = DATA_GUARD . json_encode($state);
        rewind($file);
        if (!ftruncate($file, 0) || fwrite($file, $bytes) !== strlen($bytes) || !fflush($file)) throw new RuntimeException('Rate limiter write failed');
        return $allowed;
    } finally { flock($file, LOCK_UN); fclose($file); }
}
function clean_expired(): void {
    $files = glob(storage() . '/*.php') ?: [];
    foreach ($files as $file) {
        if (!preg_match('/^(report-[a-f0-9]{32}|rate-[a-f0-9]{64})\.php$/D', basename($file))) continue;
        $age = str_starts_with(basename($file), 'report-') ? 30 * 86400 : 2 * 86400;
        if (filemtime($file) < time() - $age) @unlink($file);
    }
}
function redact(string $value, int $max = 16000): string {
    $value = substr($value, 0, $max);
    $patterns = [
        '~(?:[A-Za-z]:[\\\\/]|/(?:Users|home|volume[0-9]+)/|\\\\\\\\)[^\r\n"<>]*~u',
        '~\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b~iu',
        '~\b(?:\d{1,3}\.){3}\d{1,3}\b~u',
        '~\b(?:USB|SWD|HID)[\\\\#][^\s"<>]+~iu',
        '~\b(?:serial(?:number)?|authorization|password|token)\s*[:=]\s*[^\s,;]+~iu',
    ];
    return preg_replace($patterns, '[REDACTED]', $value) ?? '[REDACTED]';
}
function text_field(array $data, string $key, int $max = 1000): string {
    if (!isset($data[$key]) || !is_string($data[$key]) || strlen($data[$key]) > $max) throw new InvalidArgumentException('Invalid ' . $key);
    return redact($data[$key], $max);
}
function validate_report(array $data): array {
    if (($data['schema'] ?? null) !== 1 || ($data['consent'] ?? null) !== true) throw new InvalidArgumentException('Consent and schema required');
    $id = $data['id'] ?? '';
    if (!is_string($id) || !preg_match('/^[a-f0-9]{32}$/D', $id)) throw new InvalidArgumentException('Invalid id');
    $result = ['schema'=>1, 'id'=>$id, 'receivedAt'=>gmdate('c'), 'consent'=>true];
    foreach (['appVersion'=>80, 'os'=>80, 'osVersion'=>400, 'locale'=>80, 'context'=>300, 'error'=>8000, 'stack'=>24000, 'description'=>12000] as $key=>$max) {
        $result[$key] = text_field($data, $key, $max);
    }
    $contact = $data['contact'] ?? '';
    if (!is_string($contact) || strlen($contact) > 254 || ($contact !== '' && !filter_var($contact, FILTER_VALIDATE_EMAIL))) throw new InvalidArgumentException('Invalid contact');
    $result['contact'] = $contact;
    $camera = $data['camera'] ?? [];
    if (!is_array($camera)) throw new InvalidArgumentException('Invalid camera');
    $result['camera'] = [];
    foreach (['model', 'firmware', 'transport'] as $key) if (isset($camera[$key])) $result['camera'][$key] = text_field($camera, $key, 100);
    $events = $data['events'] ?? [];
    if (!is_array($events) || count($events) > 120) throw new InvalidArgumentException('Invalid events');
    $result['events'] = [];
    foreach ($events as $event) {
        if (!is_array($event)) throw new InvalidArgumentException('Invalid event');
        $row = [];
        foreach (['time'=>80, 'kind'=>80, 'message'=>2000] as $key=>$max) $row[$key] = text_field($event, $key, $max);
        $result['events'][] = $row;
    }
    return $result;
}
