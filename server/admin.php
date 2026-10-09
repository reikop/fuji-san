<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
security_headers();
header('Content-Type: text/html; charset=utf-8');
session_name('FUJISAN_ADMIN');
session_set_cookie_params(['lifetime'=>0, 'path'=>'/fuji-san/', 'secure'=>true, 'httponly'=>true, 'samesite'=>'Strict']);
ini_set('session.use_strict_mode', '1');
session_start();
if (!isset($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(24));
if (isset($_SESSION['auth']) && ($_SESSION['auth'] < time() - 3600)) unset($_SESSION['auth']);
$error = '';
try {
    clean_expired();
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (!hash_equals($_SESSION['csrf'], (string)($_POST['csrf'] ?? ''))) { http_response_code(403); exit('Invalid request'); }
        if (isset($_POST['logout'])) {
            $_SESSION = []; session_destroy(); header('Location: admin.php'); exit;
        }
        if (isset($_POST['password'])) {
            if (!rate_limit('login', 10, 900)) { http_response_code(429); $error = '잠시 후 다시 시도하세요.'; }
            elseif (is_string($_POST['password']) && strlen($_POST['password']) <= 512 && password_verify($_POST['password'], config()['admin_password_hash'])) {
                session_regenerate_id(true);
                $_SESSION['auth'] = time();
                $_SESSION['csrf'] = bin2hex(random_bytes(24));
                header('Location: admin.php'); exit;
            } else { http_response_code(401); $error = '비밀번호를 확인하세요.'; }
        }
        if (isset($_POST['delete']) && isset($_SESSION['auth'])) {
            $id = (string)$_POST['delete'];
            if (preg_match('/^[a-f0-9]{32}$/D', $id)) {
                $file = storage() . '/report-' . $id . '.php';
                if (is_file($file)) unlink($file);
            }
            header('Location: admin.php'); exit;
        }
    }
    $reports = [];
    $selected = null;
    if (isset($_SESSION['auth'])) {
        $id = $_GET['id'] ?? '';
        if (is_string($id) && preg_match('/^[a-f0-9]{32}$/D', $id) && is_file(storage() . '/report-' . $id . '.php')) $selected = read_data(storage() . '/report-' . $id . '.php');
        if ($selected && isset($_GET['download'])) {
            header('Content-Type: application/json; charset=utf-8');
            header('Content-Disposition: attachment; filename="fuji-report-' . $id . '.json"');
            echo json_encode($selected, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE); exit;
        }
        foreach (glob(storage() . '/report-*.php') ?: [] as $file) {
            $row = read_data($file);
            $summary = array_intersect_key($row, array_flip(['id','receivedAt','context','appVersion','os','camera']));
            $summary['error'] = substr($row['error'], 0, 200);
            $reports[] = $summary;
        }
        usort($reports, fn($a, $b) => strcmp($b['receivedAt'], $a['receivedAt']));
    }
} catch (Throwable $e) { http_response_code(503); $error = '보고서 저장소에 접근할 수 없습니다.'; }
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES|ENT_SUBSTITUTE, 'UTF-8'); }
?>
<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Fuji San 오류 보고</title><link rel="stylesheet" href="style.css"><main>
<h1>Fuji San 오류 보고</h1>
<?php if ($error): ?><p class="error"><?=h($error)?></p><?php endif ?>
<?php if (!isset($_SESSION['auth'])): ?>
<p>관리자만 보고서를 열람할 수 있습니다.</p>
<form method="post"><input type="hidden" name="csrf" value="<?=h($_SESSION['csrf'])?>"><label>관리자 비밀번호<input type="password" name="password" required autocomplete="current-password" maxlength="512"></label><button>로그인</button></form>
<?php else: ?>
<form method="post"><input type="hidden" name="csrf" value="<?=h($_SESSION['csrf'])?>"><button name="logout" value="1">로그아웃</button></form>
<p><?=count($reports)?>건 · 30일 보관 · 모두 사용자 제공 자료이며 내용의 진위는 확인되지 않았습니다.</p>
<?php if ($selected): ?>
<section><a href="admin.php">← 목록</a><h2><?=h($selected['context'])?></h2><p><?=h($selected['id'])?> · <?=h($selected['receivedAt'])?></p>
<a href="?id=<?=h($selected['id'])?>&amp;download=1">JSON 다운로드</a>
<pre><?=h(json_encode($selected, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE))?></pre>
<form method="post"><input type="hidden" name="csrf" value="<?=h($_SESSION['csrf'])?>"><button name="delete" value="<?=h($selected['id'])?>">이 보고서 삭제</button></form></section>
<?php endif ?>
<div class="reports"><?php foreach ($reports as $r): ?><article><a href="?id=<?=h($r['id'])?>"><strong><?=h($r['context'])?></strong></a><p><?=h($r['appVersion'])?> · <?=h($r['os'])?> · <?=h($r['camera']['model'] ?? '')?> · <?=h($r['receivedAt'])?></p><p><?=h(substr($r['error'], 0, 200))?></p></article><?php endforeach ?></div>
<?php endif ?></main></html>
