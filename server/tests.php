<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli' && !defined('FUJI_PRIVATE_TEST')) { http_response_code(404); exit; }
require_once __DIR__ . '/common.php';
function check(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$valid = ['schema'=>1,'id'=>str_repeat('a',32),'consent'=>true,'appVersion'=>'test','os'=>'test', 'osVersion'=>'test','locale'=>'ko_KR','context'=>'USB read','error'=>'0x2002','stack'=>'test stack','description'=>'test', 'contact'=>'', 'camera'=>['model'=>'X100VI','serial'=>'must not be stored'],'events'=>[['time'=>'2026-01-01','kind'=>'ptp','message'=>'read 0xd190']],'unexpected'=>'discard'];
$result = validate_report($valid);
check(!isset($result['unexpected']) && !isset($result['camera']['serial']), 'Unknown fields were not dropped');
check(count($result['events']) === 1, 'Events missing');
foreach ([['consent'=>false],['schema'=>2],['id'=>'../escape'],['contact'=>'not-email'],['events'=>array_fill(0,121,[])],['error'=>str_repeat('x',8001)]] as $patch) {
    $rejected = false;
    try { validate_report(array_merge($valid,$patch)); } catch (InvalidArgumentException $e) { $rejected = true; }
    check($rejected, 'Invalid report accepted');
}
foreach (['C:\Users\Secret Person\data.json','/home/private/data','user@example.com','10.0.0.250','serial=private-id','USB\VID_04CB\SECRET'] as $secret) {
    check(redact($secret) === '[REDACTED]', 'Redaction failed');
}
$file = storage() . '/test-' . bin2hex(random_bytes(12)) . '.php';
try {
    write_data($file, $result);
    check(str_starts_with(file_get_contents($file), DATA_GUARD), 'Missing PHP storage guard');
    check(read_data($file)['id'] === $valid['id'], 'Storage round trip failed');
} finally { if (is_file($file)) unlink($file); }
echo "PASS: report schema, consent, size limits, field allowlist, redaction, guarded storage\n";
