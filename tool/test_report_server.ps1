param([string]$BaseUrl='https://reikop.io/fuji-san', [string]$CredentialFile='.tools/report-admin-credentials.txt')
$ErrorActionPreference='Stop'
function Assert($value,[string]$message) { if (!$value) { throw $message } }
function Request([string]$method,[string]$path,$body=$null,$session=$null,[string]$type='application/json') {
    $args=@{UseBasicParsing=$true;Uri=($BaseUrl+'/'+$path);Method=$method;ContentType=$type}
    if ($null -ne $body) { $args.Body = [Text.Encoding]::UTF8.GetBytes($body) }
    if ($null -ne $session) { $args.WebSession=$session }
    try { $r=Invoke-WebRequest @args; return @{Status=[int]$r.StatusCode;Body=$r.Content} }
    catch { if ($_.Exception.Response) { return @{Status=[int]$_.Exception.Response.StatusCode;Body=[string]$_.ErrorDetails.Message} }; throw }
}
$id=[guid]::NewGuid().ToString('N')
$marker='SMOKE-'+$id
$payload=@{schema=1;id=$id;consent=$true;appVersion='smoke';os='test';osVersion='test';locale='ko_KR';context='Server smoke test';error='USB 0x2002';stack='synthetic';description=($marker+' <script>alert(1)</script> user@example.com C:\Users\Private\file.json');contact='';camera=@{model='X100VI';firmware='test';serial='must-drop'};events=@(@{time='test';kind='ptp';message='op=0x1015 code=0x2002'})}
$json=$payload|ConvertTo-Json -Depth 8 -Compress
Assert ((Request 'GET' 'report.php').Status -eq 200) 'Health failed'
Assert ((Request 'POST' 'report.php' $json).Status -eq 201) 'Submit failed'
Assert ((Request 'POST' 'report.php' $json).Status -eq 200) 'Idempotent retry failed'
$payload.consent=$false
Assert ((Request 'POST' 'report.php' ($payload|ConvertTo-Json -Depth 8 -Compress)).Status -eq 400) 'Missing consent accepted'
Assert ((Request 'POST' 'report.php' ('x'*270000)).Status -eq 413) 'Oversized body accepted'
$private=Request 'GET' ('private/report-'+$id+'.php')
Assert (($private.Status -eq 403 -or $private.Status -eq 404) -and !$private.Body.Contains($marker)) 'Report directly accessible'
$unauth=Request 'GET' ('admin.php?id='+$id+'&download=1')
Assert (!$unauth.Body.Contains($marker) -and $unauth.Body.Contains('name="password"')) 'Unauthenticated download allowed'
$session=New-Object Microsoft.PowerShell.Commands.WebRequestSession
$login=Request 'GET' 'admin.php' $null $session
$csrf=[regex]::Match($login.Body,'name="csrf" value="([a-f0-9]+)"').Groups[1].Value
$password=[regex]::Match([IO.File]::ReadAllText((Resolve-Path -LiteralPath $CredentialFile)),'(?m)^Password: (.+)$').Groups[1].Value.Trim()
Assert ($password.Length -gt 30) 'Missing credentials'
$form='csrf='+$csrf+'&password='+[uri]::EscapeDataString($password)
$loggedIn=Request 'POST' 'admin.php' $form $session 'application/x-www-form-urlencoded'
Assert ($loggedIn.Status -eq 200 -and $loggedIn.Body.Contains('name="logout"')) 'Admin login failed'
$detail=Request 'GET' ('admin.php?id='+$id) $null $session
Assert ($detail.Body.Contains('&lt;script&gt;') -and !$detail.Body.Contains('<script>')) 'Admin output is not escaped'
$download=Request 'GET' ('admin.php?id='+$id+'&download=1') $null $session
$saved=$download.Body|ConvertFrom-Json
Assert ($saved.id -eq $id -and !$saved.camera.PSObject.Properties['serial']) 'Report identity or allowlist failed'
Assert (!$saved.description.Contains('user@example.com') -and !$saved.description.Contains('Private')) 'Server redaction failed'
$delete='csrf='+[regex]::Match($detail.Body,'name="csrf" value="([a-f0-9]+)"').Groups[1].Value+'&delete='+$id
Assert ((Request 'POST' 'admin.php' $delete $session 'application/x-www-form-urlencoded').Status -eq 200) 'Delete failed'
$after=Request 'GET' ('admin.php?id='+$id+'&download=1') $null $session
Assert (!$after.Body.Contains($marker)) 'Deleted report still downloadable'
Write-Output 'PASS: HTTPS submit/retry, consent/size validation, private storage, admin login, escaped content, redacted download, deletion'
