# Tests SEC-BFF du BFF web-bff-customers (inner-donation-api/postman/PLAN-DE-TEST-E2E.md section 5.9).
# Compatible PowerShell 5.1 et 7. Aucun secret ni identifiant de session affiche. Usage :
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/sec-bff.ps1 -Cible Pile -Groupe Base
# Cibles : Pile (local/stack, https://localhost:8443, secrets du .env de la pile) ;
#          Sandbox (Route publique, oc --kubeconfig ~/.kube/sandbox.config, secrets lus dans les copies hors Git de
#          bootstrap/secrets/dev, jamais passes en argument de oc : journaux d'audit du cluster).
# Groupes : Base (rapide, sans interruption) ; BackChannel ; Refresh (~5 min, 2 instances du BFF) ;
#           Expiration (~6 min, pile seulement) ; Pannes (Keycloak, API, APISIX interne, Redis sature)
# Sandbox : SEC-BFF-11 et 14 non rejoues (meme image, prouves en pile) ; pendant Refresh et Pannes, le controleur
#           Argo CD (minikube, contexte argocd) est arrete puis toujours relance (sinon il annule les changements
#           de replicas).
param(
  [ValidateSet('Pile', 'Sandbox')]
  [string]$Cible = 'Pile',
  [Parameter(Mandatory = $true)]
  [ValidateSet('Base', 'BackChannel', 'Refresh', 'Expiration', 'Pannes')]
  [string]$Groupe
)

$ErrorActionPreference = 'Continue'
$Racine = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Stack = Join-Path -Path $Racine -ChildPath 'local\stack'
$SecretsDev = Join-Path -Path $Racine -ChildPath 'bootstrap\secrets\dev'
$Kube = Join-Path -Path $HOME -ChildPath '.kube\sandbox.config'
$Prefixe = 'web-bff-customers'
$Bff1 = 'donation-pile-web-bff-customers-1'
$Utilisateur = 'donor.a@example.test'
$Realm = 'myc-customers'
if ($Cible -eq 'Sandbox') {
  $Base = 'https://donation-gregorie769-dev.apps.rm3.7wse.p1.openshiftapps.com'
  if ($Groupe -eq 'Expiration') {
    Write-Host 'Expiration : pile seulement (il faudrait modifier la configuration du BFF deploye ; meme image)' -ForegroundColor Yellow
    exit 0
  }
}
else {
  $Base = 'https://localhost:8443'
  Set-Location -Path $Stack
}
$Travail = Join-Path -Path $env:TEMP -ChildPath ('sec-bff-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Travail | Out-Null

function Get-EnvValue([string]$Nom) {
  $ligne = Get-Content -Path (Join-Path -Path $Stack -ChildPath '.env') | Where-Object { $_ -like "$Nom=*" } | Select-Object -First 1
  if (-not $ligne) { throw "$Nom absent de local/stack/.env" }
  return $ligne.Substring($Nom.Length + 1)
}
function Get-SecretValue([string]$Fichier, [string]$Nom) {
  $m = Select-String -Path (Join-Path -Path $SecretsDev -ChildPath $Fichier) -Pattern ('^\s*' + $Nom + ':\s*"?([^"\s]+)"?\s*$') | Select-Object -First 1
  if (-not $m) { throw "$Nom absent de bootstrap/secrets/dev/$Fichier" }
  return $m.Matches[0].Groups[1].Value
}
if ($Cible -eq 'Sandbox') {
  $MotDePasse = Get-SecretValue -Fichier 'keycloak-realm-secret.dev.yaml' -Nom 'TEST_USERS_PASSWORD'
  $RedisPwd = Get-SecretValue -Fichier 'web-bff-customers-secret.dev.yaml' -Nom 'REDIS_PASSWORD'
}
else {
  $MotDePasse = Get-EnvValue -Nom 'TEST_USERS_PASSWORD'
  $RedisPwd = Get-EnvValue -Nom 'REDIS_PASSWORD'
}

$Resultats = New-Object -TypeName System.Collections.ArrayList
function Write-Resultat([string]$Id, [bool]$Ok, [string]$Detail) {
  $etat = 'ECART'; $couleur = 'Red'
  if ($Ok) { $etat = 'OK'; $couleur = 'Green' }
  [void]$Resultats.Add([pscustomobject]@{ Test = $Id; Resultat = $etat; Detail = $Detail })
  Write-Host ('{0,-12} {1,-6} {2}' -f $Id, $etat, $Detail) -ForegroundColor $couleur
}
function Write-Etape([string]$Texte) { Write-Host "--- $Texte" -ForegroundColor Cyan }
function Wait-Secondes([int]$Secondes, [string]$Motif) {
  for ($s = $Secondes; $s -gt 0; $s -= 30) {
    Write-Host ("    attente {0} s ({1})" -f $s, $Motif)
    Start-Sleep -Seconds ([Math]::Min(30, $s))
  }
}

# --- Navigateur simule (curl, une jarre de cookies par navigateur) ---
function New-Jar([string]$Nom) { return (Join-Path -Path $Travail -ChildPath "$Nom.txt") }
function Get-Cookie([string]$Jar, [string]$Nom) {
  if (-not (Test-Path -Path $Jar)) { return $null }
  foreach ($l in Get-Content -Path $Jar) {
    $c = $l -split "`t"
    if ($c.Count -ge 7 -and $c[5] -eq $Nom) { return $c[6] }
  }
  return $null
}
function Invoke-Get([string]$Jar, [string]$Url) {
  $r = "$(curl.exe -k -s -o NUL -w '%{http_code} %{redirect_url}' -b $Jar -c $Jar $Url)"
  $p = $r -split ' ', 2
  $loc = ''
  if ($p.Count -gt 1) { $loc = $p[1] }
  return [pscustomobject]@{ Code = $p[0]; Location = $loc }
}
function Get-Session([string]$Jar) {
  $json = (curl.exe -k -s -b $Jar -c $Jar "$Base/bff/api/session") -join ''
  try { return ($json | ConvertFrom-Json) } catch { return $null }
}
function Test-Connecte([string]$Jar) {
  $s = Get-Session -Jar $Jar
  return [bool]($s -and $s.authenticated)
}
function Get-PageConnexion([string]$Jar) {
  $r = Invoke-Get -Jar $Jar -Url "$Base/bff/oauth2/authorization/keycloak"
  if (-not $r.Location) { return $null }
  $html = (curl.exe -k -s -b $Jar -c $Jar $r.Location) -join "`n"
  $form = [regex]::Match($html, '<form[^>]*id="kc-form-login"[^>]*>').Value
  return [pscustomobject]@{ Autorisation = $r; Formulaire = $form }
}
# Connexion complete : autorisation (code + PKCE) -> formulaire Keycloak -> callback du BFF -> /
function Invoke-Connexion([string]$Jar) {
  $page = Get-PageConnexion -Jar $Jar
  $avant = Get-Cookie -Jar $Jar -Nom '__Host-SESSION'
  if (-not $page -or -not $page.Formulaire) {
    Write-Host '    connexion impossible : pas de formulaire Keycloak' -ForegroundColor Red
    return $null
  }
  $action = [System.Net.WebUtility]::HtmlDecode([regex]::Match($page.Formulaire, 'action="([^"]+)"').Groups[1].Value)
  $callback = "$(curl.exe -k -s -o NUL -w '%{redirect_url}' -b $Jar -c $Jar --data-urlencode "username=$Utilisateur" --data-urlencode "password=$MotDePasse" --data-urlencode 'credentialId=' $action)"
  if ($callback -notlike "$Base/bff/login/oauth2/code/keycloak*") {
    Write-Host '    connexion impossible : Keycloak n''a pas renvoye vers le callback du BFF' -ForegroundColor Red
    return $null
  }
  $retour = Invoke-Get -Jar $Jar -Url $callback
  if (-not (Test-Connecte -Jar $Jar)) {
    Write-Host "    connexion impossible : session non authentifiee apres le callback ($($retour.Location))" -ForegroundColor Red
    return $null
  }
  return [pscustomobject]@{
    Autorisation = $page.Autorisation.Location; Callback = $callback; Retour = $retour.Location
    SessionAvant = $avant; Session = (Get-Cookie -Jar $Jar -Nom '__Host-SESSION'); Connecte = (Test-Connecte -Jar $Jar)
  }
}
function Invoke-Mutation([string]$Jar, [string]$Methode, [hashtable]$Entetes) {
  $a = @('-k', '-s', '-o', 'NUL', '-w', '%{http_code}', '-b', $Jar, '-c', $Jar, '-X', $Methode,
    '-H', 'Content-Type: application/json', '--data-raw', '{}')
  foreach ($k in $Entetes.Keys) { $a += @('-H', ('{0}: {1}' -f $k, $Entetes[$k])) }
  $a += "$Base/bff/api/donors/me"
  return "$(curl.exe @a)"
}

# --- Commandes natives : stderr garde en texte (messages Redis), lignes vides de PowerShell 5.1 retirees ---
filter Out-Lignes {
  if ($_ -is [System.Management.Automation.ErrorRecord]) {
    $m = "$($_.Exception.Message)".Trim()
    if ($m -and $m -notlike '*RemoteException*') { $m }
  }
  else { "$_" }
}
function Invoke-Oc { & oc --kubeconfig $Kube @args 2>&1 | Out-Lignes }
function Join-Arguments([string[]]$Liste) {
  return (($Liste | ForEach-Object {
        if ($_ -eq '') { '""' }
        elseif ($_ -match '[\s"]') { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
        else { $_ }
      }) -join ' ')
}
# oc avec une entree standard terminee par LF seul (un pipe PowerShell ajoute CRLF, refuse par redis-cli --askpass)
function Invoke-OcAvecEntree([string[]]$Arguments, [string]$Entree) {
  $psi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command -Name oc).Source
  $psi.Arguments = Join-Arguments -Liste (@('--kubeconfig', $Kube) + $Arguments)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # PowerShell 5.1 (.NET Framework) : l'entree standard prend l'encodage de la console et ecrit son BOM en tete
  # (3 octets avant le mot de passe) ; UTF-8 sans BOM le temps du demarrage
  $encodage = [Console]::InputEncoding
  try {
    [Console]::InputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $p = [System.Diagnostics.Process]::Start($psi)
  }
  finally { [Console]::InputEncoding = $encodage }
  # Octets ASCII ecrits directement, sans encodeur texte
  $octets = [System.Text.Encoding]::ASCII.GetBytes($Entree + "`n")
  $p.StandardInput.BaseStream.Write($octets, 0, $octets.Length)
  $p.StandardInput.BaseStream.Flush()
  $p.StandardInput.Close()
  $sortie = $p.StandardOutput.ReadToEndAsync()
  $erreurs = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  return @(($sortie.Result + "`n" + $erreurs.Result) -split "`r?`n" | Where-Object { $_ -ne '' })
}

# --- Redis (utilisateur ACL de l'instance) et Keycloak (kcadm dans le conteneur / le pod) ---
# Pile : mot de passe par REDISCLI_AUTH ; Sandbox : par l'entree standard (--askpass), jamais en argument de oc exec
function Invoke-Redis {
  $a = @($args | ForEach-Object { "$_" })
  if ($Cible -eq 'Sandbox') {
    return (Invoke-OcAvecEntree -Arguments (@('exec', '-i', 'deploy/web-bff-redis', '--', 'redis-cli', '--user', $Prefixe, '--askpass') + $a) -Entree $RedisPwd)
  }
  docker compose exec -T -e "REDISCLI_AUTH=$RedisPwd" redis redis-cli --user $Prefixe @a 2>&1 | Out-Lignes
}
# Compte default de Redis (desactive : NOAUTH attendu)
function Test-RedisDefaut {
  if ($Cible -eq 'Sandbox') { return "$(Invoke-Oc exec deploy/web-bff-redis '--' redis-cli PING)" }
  return "$(docker compose exec -T redis redis-cli PING 2>&1)"
}
function Get-CleSession([string]$Id) { return "${Prefixe}:session:sessions:$Id" }
function Get-Sid([string]$Id) { return "$(Invoke-Redis GET "${Prefixe}:oidc:session:$Id")".Trim() }
# stderr affiche a part : sous PowerShell 5.1, une ligne vide de stderr devient "RemoteException" et casse le JSON
function Invoke-Kc {
  if ($Cible -eq 'Sandbox') { $sortie = & oc --kubeconfig $Kube exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh @args --config /tmp/kcadm.config 2>&1 }
  else { $sortie = docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh @args --config /tmp/kcadm.config 2>&1 }
  $sortie | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
      $m = "$($_.Exception.Message)".Trim()
      if ($m -and $m -notlike '*RemoteException*') { Write-Host "    kcadm : $m" -ForegroundColor DarkGray }
    } else { "$_" }
  }
}
function Get-KcJson { $t = (Invoke-Kc @args) -join "`n"; try { return ($t | ConvertFrom-Json) } catch { Write-Host "    kcadm : $t" -ForegroundColor Red; return $null } }
function Connect-Kc {
  if ($Cible -eq 'Sandbox') {
    # Identifiants admin lus dans l'environnement du pod Keycloak (KC_CLI_PASSWORD) : rien ne transite
    # '--' entre apostrophes : sinon PowerShell le prend pour la fin des parametres de Invoke-Oc et le retire
    Invoke-Oc exec deploy/keycloak '--' sh -c 'KC_CLI_PASSWORD=$KC_BOOTSTRAP_ADMIN_PASSWORD exec /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user $KC_BOOTSTRAP_ADMIN_USERNAME --config /tmp/kcadm.config' | Out-Null
    return
  }
  Invoke-Kc config credentials --server http://localhost:8080 --realm master --user (Get-EnvValue -Nom 'KC_BOOTSTRAP_ADMIN_USERNAME') --password (Get-EnvValue -Nom 'KC_BOOTSTRAP_ADMIN_PASSWORD') | Out-Null
}
function Get-ClientId {
  $id = "$(@(Get-KcJson get clients -r $Realm -q clientId=web-bff --fields id)[0].id)"
  if (-not $id) { throw 'id du client web-bff introuvable (kcadm)' }
  return $id
}
function Get-UserId {
  $id = "$(@(Get-KcJson get users -r $Realm -q "username=$Utilisateur" -q exact=true --fields id)[0].id)"
  if (-not $id) { throw "id de l'utilisateur $Utilisateur introuvable (kcadm)" }
  return $id
}

function Wait-Log([string]$Conteneur, [string]$Motif, [datetime]$Depuis, [int]$MaxSecondes = 120) {
  $since = $Depuis.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  for ($i = 0; $i -lt $MaxSecondes; $i += 3) {
    if (docker logs --since $since $Conteneur 2>&1 | ForEach-Object { "$_" } | Select-String -Pattern $Motif -Quiet) { return $true }
    Start-Sleep -Seconds 3
  }
  return $false
}
function Get-LogsBff([datetime]$Depuis) {
  $since = $Depuis.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  # Sandbox : toutes les instances (selecteur), journal complet depuis la date
  if ($Cible -eq 'Sandbox') { return (Invoke-Oc logs -l app.kubernetes.io/name=web-bff-customers "--since-time=$since" --tail=-1) }
  return (docker compose logs --no-log-prefix --since $since web-bff-customers 2>&1 | ForEach-Object { "$_" })
}

# --- Composants arretes / relances (Pannes) : services Compose en pile, replicas OpenShift sur le Sandbox ---
$NomsPile = @{ 'keycloak' = 'keycloak'; 'donation-api' = 'donation-api'; 'apisix-internal' = 'apisix-int' }
function Set-Replicas([string]$Deploiement, [int]$Nombre) {
  Invoke-Oc scale "deploy/$Deploiement" "--replicas=$Nombre" | Out-Null
  if ($Nombre -eq 0) { Invoke-Oc wait --for=delete pod -l "app.kubernetes.io/name=$Deploiement" --timeout=180s | Out-Null }
  else { Invoke-Oc rollout status "deploy/$Deploiement" --timeout=300s | Out-Null }
}
function Stop-Composant([string]$Nom) {
  if ($Cible -eq 'Sandbox') { Set-Replicas -Deploiement $Nom -Nombre 0 }
  else { docker compose stop $NomsPile[$Nom] | Out-Null }
}
function Start-Composant([string]$Nom) {
  if ($Cible -eq 'Sandbox') { Set-Replicas -Deploiement $Nom -Nombre 1; return $true }
  $depuis = Get-Date
  docker compose start $NomsPile[$Nom] | Out-Null
  if ($Nom -eq 'donation-api') { return (Wait-Log -Conteneur 'donation-pile-donation-api-1' -Motif 'Started ' -Depuis $depuis.AddSeconds(-5) -MaxSecondes 180) }
  return $true
}
function Restart-Bff {
  if ($Cible -eq 'Sandbox') {
    Invoke-Oc rollout restart deploy/web-bff-customers | Out-Null
    Invoke-Oc rollout status deploy/web-bff-customers --timeout=300s | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  $depuis = Get-Date
  docker compose restart web-bff-customers | Out-Null
  return (Wait-Log -Conteneur $Bff1 -Motif 'Started WebBffApplication' -Depuis $depuis.AddSeconds(-5))
}
# Sandbox : Argo CD remettrait aussitot les replicas de Git ; son controleur est arrete le temps du groupe
function Suspend-Argo {
  kubectl --context argocd -n argocd scale statefulset argocd-application-controller --replicas=0 2>&1 | Out-Lignes | Out-Null
  Write-Host '    controleur Argo CD arrete (le temps du groupe)' -ForegroundColor Yellow
}
function Resume-Argo {
  kubectl --context argocd -n argocd scale statefulset argocd-application-controller --replicas=1 2>&1 | Out-Lignes | Out-Null
  Write-Host '    controleur Argo CD relance' -ForegroundColor Yellow
}
function Show-EtatSandbox {
  $pasPrets = @(Invoke-Oc get deploy --no-headers | Where-Object { $_ -and $_ -notmatch '\s1/1\s' } | ForEach-Object { ($_ -split '\s+')[0] })
  $restantes = @(Invoke-Redis --scan --pattern "${Prefixe}:remplissage:*" | Where-Object { $_ }).Count
  Write-Resultat 'etat final' ($pasPrets.Count -eq 0 -and $restantes -eq 0) ("deploiements pas a 1/1 : {0} ; cles de remplissage restantes : {1}" -f ($(if ($pasPrets.Count) { $pasPrets -join ', ' } else { 'aucun' })), $restantes)
}
# Service pret VU PAR APISIX externe : 3 reponses attendues de suite (cache DNS d'APISIX, demarrage de Keycloak)
function Wait-Url([string]$Url, [string[]]$Codes, [int]$MaxSecondes = 180) {
  $suite = 0
  for ($i = 0; $i -lt $MaxSecondes; $i += 2) {
    $code = "$(curl.exe -k -s -o NUL -w '%{http_code}' $Url)"
    if ($Codes -contains $code) { $suite++ } else { $suite = 0 }
    if ($suite -ge 3) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}
function Wait-Keycloak { return (Wait-Url -Url "$Base/realms/$Realm/.well-known/openid-configuration" -Codes @('200')) }
function Wait-BffPublic { return (Wait-Url -Url "$Base/bff/api/session" -Codes @('200')) }

# =====================================================================================================================
if ($Groupe -eq 'Base') {
  Write-Etape 'SEC-BFF-02 / 05 : connexion, PKCE S256, fixation de session'
  $jar = New-Jar -Nom 'base'
  $c = Invoke-Connexion -Jar $jar
  if ($c) {
    Write-Resultat 'SEC-BFF-02' ($c.Autorisation -match 'code_challenge_method=S256' -and $c.Connecte) 'PKCE S256 et session authentifiee'
    $ancienne = "$(Invoke-Redis EXISTS (Get-CleSession -Id $c.SessionAvant))".Trim()
    $nouvelle = "$(Invoke-Redis EXISTS (Get-CleSession -Id $c.Session))".Trim()
    Write-Resultat 'SEC-BFF-05' ($c.SessionAvant -and $c.SessionAvant -ne $c.Session -and $ancienne -eq '0' -and $nouvelle -eq '1') ("identifiant change a la connexion : {0} ; ancienne cle presente : {1} ; nouvelle : {2}" -f ($c.SessionAvant -ne $c.Session), $ancienne, $nouvelle)

    Write-Etape 'SEC-BFF-13 : CSRF et Origin (mutation POST /bff/api/donors/me, corps vide)'
    $x = Get-Cookie -Jar $jar -Nom 'XSRF-TOKEN'
    $cas = @(
      @('POST sans jeton', 'POST', @{ Origin = $Base }, '403'),
      @('POST jeton faux', 'POST', @{ Origin = $Base; 'X-XSRF-TOKEN' = 'faux' }, '403'),
      @('POST sans Origin', 'POST', @{ 'X-XSRF-TOKEN' = $x }, '403'),
      @('POST Origin etrangere', 'POST', @{ Origin = 'https://attaquant.example'; 'X-XSRF-TOKEN' = $x }, '403'),
      @('POST Sec-Fetch-Site cross-site', 'POST', @{ 'Sec-Fetch-Site' = 'cross-site'; 'X-XSRF-TOKEN' = $x }, '403'),
      @('PUT sans jeton', 'PUT', @{ Origin = $Base }, '403'),
      @('PATCH sans jeton', 'PATCH', @{ Origin = $Base }, '403'),
      @('DELETE sans jeton', 'DELETE', @{ Origin = $Base }, '403')
    )
    $ok = $true; $detail = @()
    foreach ($k in $cas) {
      $code = Invoke-Mutation -Jar $jar -Methode $k[1] -Entetes $k[2]
      if ($code -ne $k[3]) { $ok = $false }
      $detail += "$($k[0])=$code"
    }
    Write-Resultat 'SEC-BFF-13a' $ok ($detail -join ' ; ')
    $code = Invoke-Mutation -Jar $jar -Methode 'POST' -Entetes @{ Origin = $Base; 'X-XSRF-TOKEN' = $x }
    Write-Resultat 'SEC-BFF-13b' ($code -eq '400') "requete conforme (jeton + Origin, corps invalide) -> $code (attendu 400 : CSRF passe, validation refuse)"

    Write-Etape 'SEC-BFF-09 : deconnexion RP-Initiated puis nouvelle demande du mot de passe'
    $avant = $c.Session
    $r = "$(curl.exe -k -s -o NUL -w '%{http_code} %{redirect_url}' -b $jar -c $jar -X POST -H "Origin: $Base" -H "X-XSRF-TOKEN: $x" "$Base/bff/logout")" -split ' ', 2
    $versKeycloak = ($r.Count -gt 1 -and $r[1] -like "$Base/realms/$Realm/protocol/openid-connect/logout*")
    $fin = Invoke-Get -Jar $jar -Url $r[1]
    $existe = "$(Invoke-Redis EXISTS (Get-CleSession -Id $avant))".Trim()
    $page = Get-PageConnexion -Jar $jar
    Write-Resultat 'SEC-BFF-09' ($versKeycloak -and $fin.Location -like "$Base/*" -and $existe -eq '0' -and -not (Test-Connecte -Jar $jar) -and $page.Formulaire) ("end_session : {0} ; retour : {1} ; cle de session presente : {2} ; mot de passe redemande : {3}" -f $versKeycloak, $fin.Location, $existe, [bool]$page.Formulaire)
    Write-Etape 'SEC-BFF-04 : callback rejoue, state faux'
    $r = Invoke-Get -Jar $jar -Url $c.Callback
    Write-Resultat 'SEC-BFF-04a' ($r.Location -match 'connexion=echec') "callback rejoue par le meme navigateur -> $($r.Location)"
    $jar2 = New-Jar -Nom 'rejeu'
    $r = Invoke-Get -Jar $jar2 -Url $c.Callback
    Write-Resultat 'SEC-BFF-04b' ($r.Location -match 'connexion=echec' -and -not (Test-Connecte -Jar $jar2)) "callback rejoue par un autre navigateur -> $($r.Location), anonyme"
    $jar3 = New-Jar -Nom 'state'
    $r = Invoke-Get -Jar $jar3 -Url "$Base/bff/login/oauth2/code/keycloak?code=faux&state=faux"
    Write-Resultat 'SEC-BFF-04c' ($r.Location -match 'connexion=echec' -and -not (Test-Connecte -Jar $jar3)) "state faux -> $($r.Location), anonyme"

  }

  Write-Etape 'SEC-BFF-15a : API sans session'
  $jar4 = New-Jar -Nom 'anonyme'
  $r = Invoke-Get -Jar $jar4 -Url "$Base/bff/api/donors/me"
  Write-Resultat 'SEC-BFF-15a' ($r.Code -eq '401') "GET /bff/api/donors/me sans session -> $($r.Code)"

  Write-Etape 'SEC-BFF-03 : Redis (ACL de l''instance)'
  $cles = @(Invoke-Redis --scan --pattern '*' | Where-Object { $_ })
  $horsPrefixe = @($cles | Where-Object { $_ -notlike "${Prefixe}:*" }).Count
  $get = "$(Invoke-Redis GET autre:cle)"
  $keys = "$(Invoke-Redis KEYS '*')"
  $defaut = Test-RedisDefaut
  Write-Resultat 'SEC-BFF-03' ($horsPrefixe -eq 0 -and $get -match 'NOPERM' -and $keys -match 'NOPERM' -and $defaut -match 'NOAUTH') ("{0} cles, {1} hors prefixe ; GET hors prefixe : {2} ; KEYS : {3} ; compte default : {4}" -f $cles.Count, $horsPrefixe, ($get -replace '^(\S+).*', '$1'), ($keys -replace '^(\S+).*', '$1'), ($defaut -replace '^(\S+).*', '$1'))

  Write-Etape 'SEC-BFF-06 : token limite a l''API (claims d''exemple Keycloak, jamais de token) ; APISIX interne'
  Connect-Kc
  $cid = Get-ClientId; $uid = Get-UserId
  $brut = (Invoke-Kc get "clients/$cid/evaluate-scopes/generate-example-access-token" -r $Realm -q 'scope=openid profile email donation:read donation:write' -q "userId=$uid") -join "`n"
  $aud = [regex]::Match($brut, '"aud"\s*:\s*("[^"]*"|\[[^\]]*\])').Groups[1].Value
  $azp = [regex]::Match($brut, '"azp"\s*:\s*"([^"]*)"').Groups[1].Value
  $scope = [regex]::Match($brut, '"scope"\s*:\s*"([^"]*)"').Groups[1].Value
  Write-Resultat 'SEC-BFF-06a' ($aud -match '"donation-api"' -and $azp -eq 'web-bff' -and $scope -match 'donation:read' -and $scope -match 'donation:write') ("aud={0} ; azp={1} ; scope={2}" -f $aud, $azp, $scope)
  $sans = Invoke-Get -Jar $jar4 -Url "$Base/api/v1/donors/me"
  $faux = "$(curl.exe -k -s -o NUL -w '%{http_code}' -H 'Authorization: Bearer abc.def.ghi' "$Base/api/v1/donors/me")"
  Write-Resultat 'SEC-BFF-06b' ($sans.Code -eq '401' -and $faux -eq '401') "APISIX interne : sans token -> $($sans.Code) ; token faux -> $faux"
}

# =====================================================================================================================
if ($Groupe -eq 'BackChannel') {
  Connect-Kc
  Write-Etape 'SEC-BFF-10 : back-channel cible (deux navigateurs, une seule session Keycloak supprimee)'
  $jarA = New-Jar -Nom 'a'; $jarB = New-Jar -Nom 'b'
  $a = Invoke-Connexion -Jar $jarA; $b = Invoke-Connexion -Jar $jarB
  if ($a -and $b) {
    $sidA = Get-Sid -Id $a.Session; $sidB = Get-Sid -Id $b.Session
    $depuis = Get-Date
    Invoke-Kc delete "sessions/$sidA" -r $Realm | Out-Null
    Start-Sleep -Seconds 3
    $logs = Get-LogsBff -Depuis $depuis.AddSeconds(-2)
    $okLog = [bool]($logs | Select-String -Pattern 'backchannel\.ok.*sessionsSupprimees=1')
    Write-Resultat 'SEC-BFF-10' ($sidA -and $sidA -ne $sidB -and -not (Test-Connecte -Jar $jarA) -and (Test-Connecte -Jar $jarB) -and $okLog) ("sid distincts : {0} ; A deconnecte : {1} ; B toujours connecte : {2} ; log backchannel.ok : {3}" -f ($sidA -ne $sidB), (-not (Test-Connecte -Jar $jarA)), (Test-Connecte -Jar $jarB), $okLog)
  }

  if ($Cible -eq 'Sandbox') {
    Write-Host '    SEC-BFF-11 : pile seulement (capture par un conteneur sur le reseau de Keycloak ; meme image)' -ForegroundColor Yellow
  }
  else {
    Write-Etape 'SEC-BFF-11 : rejeu d''un logout_token (capture, puis deux envois au BFF)'
    $jarC = New-Jar -Nom 'c'
    $c = Invoke-Connexion -Jar $jarC
    if ($c) {
      $sidC = Get-Sid -Id $c.Session
      $cid = Get-ClientId
      $client = (Invoke-Kc get "clients/$cid" -r $Realm) -join "`n"
      $origine = [regex]::Match($client, '"backchannel\.logout\.url"\s*:\s*"([^"]+)"').Groups[1].Value
      if (-not $origine) { throw 'URL de back-channel du client web-bff introuvable : test arrete, rien n''a ete modifie' }
      [System.IO.File]::WriteAllText((Join-Path -Path $Travail -ChildPath 'client-origine.json'), $client)
      [System.IO.File]::WriteAllText((Join-Path -Path $Travail -ChildPath 'client-capture.json'), $client.Replace($origine, 'http://capture-backchannel:8080/'))
      @'
import http.server, sys, urllib.error, urllib.request
BFF = 'http://web-bff-customers:8080/bff/logout/connect/back-channel/keycloak'
class Capture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.server.corps = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('0.0.0.0', 8080), Capture)
srv.corps = None
srv.timeout = 60
srv.handle_request()
if not srv.corps:
    print('CAPTURE absente')
    sys.exit(1)
print('CAPTURE ok (logout_token non affiche)')
for essai in (1, 2):
    req = urllib.request.Request(BFF, data=srv.corps, headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        code = urllib.request.urlopen(req, timeout=10).status
    except urllib.error.HTTPError as e:
        code = e.code
    print('ENVOI', essai, code)
'@ | Set-Content -Path (Join-Path -Path $Travail -ChildPath 'capture.py') -Encoding ascii
      docker run -d --name capture-backchannel --network donation-pile-idp -v "${Travail}:/t:ro" python:3.12-alpine python /t/capture.py | Out-Null
      Start-Sleep -Seconds 3
      docker compose cp (Join-Path -Path $Travail -ChildPath 'client-capture.json') keycloak:/tmp/client-capture.json
      Invoke-Kc update "clients/$cid" -r $Realm -f /tmp/client-capture.json
      $capture = [regex]::Match(((Invoke-Kc get "clients/$cid" -r $Realm) -join "`n"), '"backchannel\.logout\.url"\s*:\s*"([^"]+)"').Groups[1].Value
      Write-Host "    URL de back-channel pendant le test : $capture"
      $depuis = Get-Date
      Invoke-Kc delete "sessions/$sidC" -r $Realm | Out-Null
      docker wait capture-backchannel | Out-Null
      $sortie = @(docker logs capture-backchannel 2>&1 | ForEach-Object { "$_" })
      docker rm capture-backchannel | Out-Null
      docker compose cp (Join-Path -Path $Travail -ChildPath 'client-origine.json') keycloak:/tmp/client-origine.json
      Invoke-Kc update "clients/$cid" -r $Realm -f /tmp/client-origine.json
      # La representation du client contient son secret : supprimee du conteneur et du dossier de travail
      # Copies faites par docker compose cp : proprietaire root dans /tmp (sticky bit), donc suppression en root
      docker compose exec -T -u root keycloak rm -f /tmp/client-origine.json /tmp/client-capture.json
      Remove-Item -Path (Join-Path -Path $Travail -ChildPath 'client-*.json') -Force
      $restaure = [regex]::Match(((Invoke-Kc get "clients/$cid" -r $Realm) -join "`n"), '"backchannel\.logout\.url"\s*:\s*"([^"]+)"').Groups[1].Value
      $logs = Get-LogsBff -Depuis $depuis.AddSeconds(-2)
      $envois = ($sortie | Where-Object { $_ -like 'ENVOI*' }) -join ' ; '
      $rejeu = [bool]($logs | Select-String -Pattern 'backchannel\.rejeu')
      Write-Resultat 'SEC-BFF-11' ($envois -eq 'ENVOI 1 200 ; ENVOI 2 200' -and $rejeu -and -not (Test-Connecte -Jar $jarC)) ("{0} ; {1} ; log backchannel.rejeu : {2} ; session supprimee : {3}" -f ($sortie | Select-Object -First 1), $envois, $rejeu, (-not (Test-Connecte -Jar $jarC)))
      Write-Resultat 'restauration' ($restaure -and $restaure -eq $origine) "URL de back-channel du client web-bff restauree : $restaure"
    }
  }
}

# =====================================================================================================================
if ($Groupe -eq 'Refresh' -and $Cible -eq 'Pile') {
  Connect-Kc
  Write-Etape 'Deuxieme instance du BFF (meme Redis)'
  $depuis = Get-Date
  docker compose up -d --scale web-bff-customers=2 --no-recreate web-bff-customers
  $bff2 = 'donation-pile-web-bff-customers-2'
  if (-not (Wait-Log -Conteneur $bff2 -Motif 'Started WebBffApplication' -Depuis $depuis.AddSeconds(-5))) { Write-Host '    instance 2 non demarree' -ForegroundColor Red }

  Write-Etape 'Connexions R (refresh concurrent) et V (refresh revoque)'
  $jarR = New-Jar -Nom 'r'; $jarV = New-Jar -Nom 'v'
  $r = Invoke-Connexion -Jar $jarR; $v = Invoke-Connexion -Jar $jarV
  if ($r -and $v) {
    # V : on retire la session V du registre du BFF (le back-channel ne la trouvera pas), puis Keycloak la supprime :
    # seul le refresh peut detecter la revocation
    $sidV = Get-Sid -Id $v.Session
    Invoke-Redis DEL "${Prefixe}:oidc:session:$($v.Session)" | Out-Null
    Invoke-Redis SREM "${Prefixe}:oidc:sid:$sidV" $v.Session | Out-Null
    Invoke-Kc delete "sessions/$sidV" -r $Realm | Out-Null
    Write-Host ("    V encore connecte cote BFF avant expiration du token : {0}" -f (Test-Connecte -Jar $jarV))

    Wait-Secondes -Secondes 285 -Motif 'access token de 5 min : refresh 30 s avant expiration'

    Write-Etape 'SEC-BFF-07 : 6 requetes simultanees, 3 par instance, meme session'
    @'
import os, threading, urllib.error, urllib.request
cookie = '__Host-SESSION=' + os.environ['SESSION']
urls = ['http://donation-pile-web-bff-customers-1:8080/bff/api/donors/me',
        'http://donation-pile-web-bff-customers-2:8080/bff/api/donors/me'] * 3
barriere = threading.Barrier(len(urls))
codes = [None] * len(urls)
def appel(i, url):
    req = urllib.request.Request(url, headers={'Cookie': cookie})
    barriere.wait()
    try:
        codes[i] = urllib.request.urlopen(req, timeout=20).status
    except urllib.error.HTTPError as e:
        codes[i] = e.code
    except Exception as e:
        codes[i] = type(e).__name__
fils = [threading.Thread(target=appel, args=(i, u)) for i, u in enumerate(urls)]
for f in fils:
    f.start()
for f in fils:
    f.join()
print(' '.join(str(c) for c in codes))
'@ | Set-Content -Path (Join-Path -Path $Travail -ChildPath 'parallele.py') -Encoding ascii
    $depuis = Get-Date
    $codes = "$(docker run --rm --network donation-pile-bff -e "SESSION=$($r.Session)" -v "${Travail}:/t:ro" python:3.12-alpine python /t/parallele.py)".Trim()
    Start-Sleep -Seconds 2
    $logs = Get-LogsBff -Depuis $depuis.AddSeconds(-2)
    $nbRefresh = @($logs | Select-String -Pattern 'refresh\.ok').Count
    $nbRelu = @($logs | Select-String -Pattern 'refresh\.attente\.relu').Count
    $nbEchec = @($logs | Select-String -Pattern 'refresh\.verrou\.delai|autorisation\.refusee').Count
    $codesOk = -not ($codes -split ' ' | Where-Object { $_ -notin @('200', '404') })
    Write-Resultat 'SEC-BFF-07' ($codesOk -and $nbRefresh -eq 1 -and $nbEchec -eq 0 -and (Test-Connecte -Jar $jarR)) ("codes : {0} ; refresh.ok : {1} ; attente.relu : {2} ; echecs : {3} ; toujours connecte : {4}" -f $codes, $nbRefresh, $nbRelu, $nbEchec, (Test-Connecte -Jar $jarR))

    Write-Etape 'SEC-BFF-08 : refresh d''une session revoquee dans Keycloak'
    $depuis = Get-Date
    $code = (Invoke-Get -Jar $jarV -Url "$Base/bff/api/donors/me").Code
    Start-Sleep -Seconds 1
    $refus = [bool](Get-LogsBff -Depuis $depuis.AddSeconds(-2) | Select-String -Pattern 'autorisation\.refusee')
    Write-Resultat 'SEC-BFF-08' ($code -eq '401' -and $refus -and -not (Test-Connecte -Jar $jarV)) ("GET /bff/api/donors/me -> {0} ; log autorisation.refusee : {1} ; session BFF supprimee : {2}" -f $code, $refus, (-not (Test-Connecte -Jar $jarV)))
  }
  Write-Etape 'Retour a une instance'
  docker compose up -d --scale web-bff-customers=1 web-bff-customers
  Write-Host ("    BFF joignable par APISIX : {0}" -f (Wait-BffPublic))
}

# =====================================================================================================================
if ($Groupe -eq 'Refresh' -and $Cible -eq 'Sandbox') {
  Connect-Kc
  Suspend-Argo
  try {
    Write-Etape 'Deuxieme instance du BFF (meme Redis)'
    Set-Replicas -Deploiement 'web-bff-customers' -Nombre 2
    Write-Host ("    2 instances pretes, BFF joignable par APISIX : {0}" -f (Wait-BffPublic))

    Write-Etape 'Connexions R (refresh concurrent) et V (refresh revoque)'
    $jarR = New-Jar -Nom 'r'; $jarV = New-Jar -Nom 'v'
    $r = Invoke-Connexion -Jar $jarR; $v = Invoke-Connexion -Jar $jarV
    if ($r -and $v) {
      # V : on retire la session V du registre du BFF (le back-channel ne la trouvera pas), puis Keycloak la supprime :
      # seul le refresh peut detecter la revocation
      $sidV = Get-Sid -Id $v.Session
      Invoke-Redis DEL "${Prefixe}:oidc:session:$($v.Session)" | Out-Null
      Invoke-Redis SREM "${Prefixe}:oidc:sid:$sidV" $v.Session | Out-Null
      Invoke-Kc delete "sessions/$sidV" -r $Realm | Out-Null
      Write-Host ("    V encore connecte cote BFF avant expiration du token : {0}" -f (Test-Connecte -Jar $jarV))

      Wait-Secondes -Secondes 285 -Motif 'access token de 5 min : refresh 30 s avant expiration'

      Write-Etape 'SEC-BFF-07 : 6 requetes simultanees par la Route publique (le Service repartit sur les 2 instances), meme session'
      $parallele = @('-k', '-s', '--parallel', '--parallel-immediate', '--parallel-max', '6', '-b', $jarR, '-w', '%{http_code} ')
      for ($n = 0; $n -lt 6; $n++) { $parallele += @('-o', 'NUL', "$Base/bff/api/donors/me") }
      $depuis = Get-Date
      $codes = "$(curl.exe @parallele)".Trim()
      Start-Sleep -Seconds 2
      $logs = Get-LogsBff -Depuis $depuis.AddSeconds(-2)
      $nbRefresh = @($logs | Select-String -Pattern 'refresh\.ok').Count
      $nbRelu = @($logs | Select-String -Pattern 'refresh\.attente\.relu').Count
      $nbEchec = @($logs | Select-String -Pattern 'refresh\.verrou\.delai|autorisation\.refusee').Count
      $instances = @($logs | Select-String -Pattern 'refresh\.(ok|attente\.relu)' | ForEach-Object { [regex]::Match($_.Line, '"node":\{"name":"([^"]+)"').Groups[1].Value } | Where-Object { $_ } | Sort-Object -Unique).Count
      $codesOk = ($codes -split ' ').Count -eq 6 -and -not ($codes -split ' ' | Where-Object { $_ -notin @('200', '404') })
      Write-Resultat 'SEC-BFF-07' ($codesOk -and $nbRefresh -eq 1 -and $nbEchec -eq 0 -and (Test-Connecte -Jar $jarR)) ("codes : {0} ; refresh.ok : {1} ; attente.relu : {2} ; echecs : {3} ; instances concernees : {4} ; toujours connecte : {5}" -f $codes, $nbRefresh, $nbRelu, $nbEchec, $instances, (Test-Connecte -Jar $jarR))

      Write-Etape 'SEC-BFF-08 : refresh d''une session revoquee dans Keycloak'
      $depuis = Get-Date
      $code = (Invoke-Get -Jar $jarV -Url "$Base/bff/api/donors/me").Code
      Start-Sleep -Seconds 1
      $refus = [bool](Get-LogsBff -Depuis $depuis.AddSeconds(-2) | Select-String -Pattern 'autorisation\.refusee')
      Write-Resultat 'SEC-BFF-08' ($code -eq '401' -and $refus -and -not (Test-Connecte -Jar $jarV)) ("GET /bff/api/donors/me -> {0} ; log autorisation.refusee : {1} ; session BFF supprimee : {2}" -f $code, $refus, (-not (Test-Connecte -Jar $jarV)))
    }
  }
  finally {
    Write-Etape 'Retour a une instance'
    Set-Replicas -Deploiement 'web-bff-customers' -Nombre 1
    Resume-Argo
    Write-Host ("    BFF joignable par APISIX : {0}" -f (Wait-BffPublic))
  }
  Show-EtatSandbox
}

# =====================================================================================================================
if ($Groupe -eq 'Expiration') {
  Write-Etape 'BFF recree avec inactivite 2 min et duree absolue 5 min'
  $court = Join-Path -Path $Travail -ChildPath 'court.yaml'
  "services:`n  web-bff-customers:`n    environment:`n      SESSION_IDLE_TIMEOUT: 2m`n      SESSION_ABSOLUTE_TIMEOUT: 5m`n" | Set-Content -Path $court -Encoding ascii
  $depuis = Get-Date
  docker compose -f compose.yaml -f $court up -d web-bff-customers
  if ((Wait-Log -Conteneur $Bff1 -Motif 'Started WebBffApplication' -Depuis $depuis.AddSeconds(-5)) -and (Wait-BffPublic)) {
    $jarI = New-Jar -Nom 'inactif'; $jarA = New-Jar -Nom 'actif'
    $i = Invoke-Connexion -Jar $jarI; $a = Invoke-Connexion -Jar $jarA
    $t0 = Get-Date
    if ($i -and $a) {
      while (((Get-Date) - $t0).TotalSeconds -lt 135) { Start-Sleep -Seconds 45; Write-Host ("    A actif : {0}" -f (Test-Connecte -Jar $jarA)) }
      $inactif = Test-Connecte -Jar $jarI; $actif = Test-Connecte -Jar $jarA
      Write-Resultat 'SEC-BFF-14a' (-not $inactif -and $actif) ("apres 2 min 15 : session inactive expiree : {0} ; session active conservee : {1}" -f (-not $inactif), $actif)
      while (((Get-Date) - $t0).TotalSeconds -lt 310) { Start-Sleep -Seconds 45; Write-Host ("    A actif : {0}" -f (Test-Connecte -Jar $jarA)) }
      $actif = Test-Connecte -Jar $jarA
      Write-Resultat 'SEC-BFF-14b' (-not $actif) "apres 5 min 10 : session active invalidee (duree absolue) : $(-not $actif)"
    }
  }
  else { Write-Host '    BFF non demarre' -ForegroundColor Red }
  Write-Etape 'Restauration de la configuration du BFF'
  $depuis = Get-Date
  docker compose up -d web-bff-customers
  Write-Host ("    BFF redemarre et joignable par APISIX : {0}" -f ((Wait-Log -Conteneur $Bff1 -Motif 'Started WebBffApplication' -Depuis $depuis.AddSeconds(-5)) -and (Wait-BffPublic)))
}

# =====================================================================================================================
if ($Groupe -eq 'Pannes') {
  if ($Cible -eq 'Sandbox') { Suspend-Argo }
  try {
    Write-Etape 'SEC-BFF-01 : demarrage du BFF sans Keycloak'
    Stop-Composant -Nom 'keycloak'
    $demarre = (Restart-Bff) -and (Wait-BffPublic)
    $jarK = New-Jar -Nom 'sans-keycloak'
    $s = Invoke-Get -Jar $jarK -Url "$Base/bff/api/session"
    $auth = Invoke-Get -Jar $jarK -Url "$Base/bff/oauth2/authorization/keycloak"
    Write-Resultat 'SEC-BFF-01' ($demarre -and $s.Code -eq '200' -and $auth.Code -eq '302' -and $auth.Location -like "$Base/realms/$Realm/protocol/openid-connect/auth*") ("demarre : {0} ; /bff/api/session : {1} ; autorisation : {2} vers l'emetteur public : {3}" -f $demarre, $s.Code, $auth.Code, ($auth.Location -like "$Base/realms/$Realm/*"))
    Start-Composant -Nom 'keycloak' | Out-Null
    Write-Host ("    Keycloak pret (vu par APISIX externe) : {0}" -f (Wait-Keycloak))

    Write-Etape 'SEC-BFF-15 : erreurs de l''API sans fuite'
    $jarE = New-Jar -Nom 'erreurs'
    $e = Invoke-Connexion -Jar $jarE
    if ($e) {
      $fuite = 'apisix|donation-api|http://|Exception|trace|at ma\.|at org\.'
      Stop-Composant -Nom 'donation-api'
      $corps = (curl.exe -k -s -w "`n%{http_code}" -b $jarE -c $jarE "$Base/bff/api/donors/me") -join "`n"
      $code = ($corps -split "`n")[-1]
      Write-Resultat 'SEC-BFF-15b' ($code -eq '502' -and $corps -notmatch $fuite) "API arretee -> $code ; detail interne : $($corps -match $fuite)"
      $pret = Start-Composant -Nom 'donation-api'
      Write-Host ("    API redemarree et joignable par APISIX interne : {0}" -f ($pret -and (Wait-Url -Url "$Base/api/v1/donors/me" -Codes @('401'))))
      Stop-Composant -Nom 'apisix-internal'
      $corps = (curl.exe -k -s -w "`n%{http_code}" -b $jarE -c $jarE "$Base/bff/api/donors/me") -join "`n"
      $code = ($corps -split "`n")[-1]
      Write-Resultat 'SEC-BFF-15c' ($code -eq '503' -and $corps -notmatch $fuite) "APISIX interne arrete -> $code ; detail interne : $($corps -match $fuite)"
      Start-Composant -Nom 'apisix-internal' | Out-Null
      Write-Host ("    APISIX interne joignable : {0}" -f (Wait-Url -Url "$Base/api/v1/donors/me" -Codes @('401')))
      $code = (Invoke-Get -Jar $jarE -Url "$Base/bff/api/donors/me").Code
      Write-Host "    retour a la normale : GET /bff/api/donors/me -> $code"
    }

    Write-Etape 'SEC-BFF-12 : Redis sature (noeviction)'
    $jarS = New-Jar -Nom 'existante'
    $s1 = Invoke-Connexion -Jar $jarS
    if ($s1) {
      $remplir = 'for i=1,80 do redis.call(''SET'', KEYS[1] .. i, string.rep(''x'', 1048576)) end return 0'
      $vider = 'for i=1,80 do redis.call(''DEL'', KEYS[1] .. i) end return 0'
      $plein = "$(Invoke-Redis EVAL $remplir 1 "${Prefixe}:remplissage:")"
      $memoire = (Invoke-Redis INFO memory | Where-Object { $_ -match '^(used_memory_human|maxmemory_human):' }) -join ' '
      Write-Host "    remplissage : $($plein -replace '^(\S+).*', '$1') ; $memoire"
      $jarN = New-Jar -Nom 'nouvelle'
      $n = Invoke-Get -Jar $jarN -Url "$Base/bff/oauth2/authorization/keycloak"
      $existe = "$(Invoke-Redis EXISTS (Get-CleSession -Id $s1.Session))".Trim()
      Invoke-Redis EVAL $vider 1 "${Prefixe}:remplissage:" | Out-Null
      $restantes = @(Invoke-Redis --scan --pattern "${Prefixe}:remplissage:*" | Where-Object { $_ }).Count
      $toujours = Test-Connecte -Jar $jarS
      $jarN2 = New-Jar -Nom 'apres'
      $n2 = Invoke-Connexion -Jar $jarN2
      Write-Resultat 'SEC-BFF-12' ($n.Code -eq '503' -and $existe -eq '1' -and $toujours -and $n2 -and $n2.Connecte) ("nouvelle connexion pendant saturation -> {0} (attendu 503) ; session existante conservee : {1} ; utilisable apres liberation : {2} ; nouvelle connexion apres : {3} ; cles de remplissage restantes : {4}" -f $n.Code, ($existe -eq '1'), $toujours, [bool]($n2 -and $n2.Connecte), $restantes)
    }
  }
  finally {
    if ($Cible -eq 'Sandbox') {
      # Composants toujours remis a 1, meme si un test a echoue en cours de route
      foreach ($d in @('keycloak', 'donation-api', 'apisix-internal')) {
        if ("$(Invoke-Oc get deploy $d -o 'jsonpath={.spec.replicas}')" -eq '0') { Set-Replicas -Deploiement $d -Nombre 1 }
      }
      Resume-Argo
    }
  }
  if ($Cible -eq 'Sandbox') { Show-EtatSandbox }
}

Write-Host ''
Write-Host "=== Synthese ($Groupe)" -ForegroundColor Cyan
$Resultats | Format-Table -AutoSize -Wrap
Remove-Item -Path $Travail -Recurse -Force
