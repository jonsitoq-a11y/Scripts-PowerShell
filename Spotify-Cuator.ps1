# ====================================================================
# Spotify Playlist Curator – Auto-refresh OAUTH + PIOLÍN RBA
# ====================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web

$clientId     = "9a93393f30174a94ae673934761b65ec"
$clientSecret = "TuClientSecret"
$redirectUri  = "http://127.0.0.1:8888/callback"
$scopes       = "playlist-read-private playlist-modify-private playlist-modify-public user-top-read user-library-read"
$tokenFile    = Join-Path $PSScriptRoot "spotify_token.json"
$listenerPref = "http://127.0.0.1:8888/"

Function Write-Info($m){Write-Host $m -ForegroundColor Cyan}
Function Write-Good($m){Write-Host $m -ForegroundColor Green}
Function Write-Warn($m){Write-Host $m -ForegroundColor Yellow}
Function Write-Err($m){Write-Host $m -ForegroundColor Red}

Function Start-AuthFlow {
  Write-Info "🔐 Iniciando OAuth..."
  $url = "https://accounts.spotify.com/authorize?client_id=$clientId&response_type=code&redirect_uri=$([System.Web.HttpUtility]::UrlEncode($redirectUri))&scope=$([System.Web.HttpUtility]::UrlEncode($scopes))&show_dialog=true"
  $http = New-Object System.Net.HttpListener
  $http.Prefixes.Add($listenerPref)
  try { $http.Start() } catch { Write-Err "Error, cierra el Flask si está usando ese puerto"; throw }
  Start-Process $url
  $ctx = $http.GetContext(); $req = $ctx.Request; $res = $ctx.Response; $http.Stop()
  $code = $req.QueryString["code"]
  $html = [Text.Encoding]::UTF8.GetBytes("<html><body><h2>Autenticación completa</h2><p>Cierra esta pestaña.</p></body></html>")
  $res.ContentType = "text/html"; $res.ContentLength64 = $html.Length
  $res.OutputStream.Write($html,0,$html.Length); $res.OutputStream.Close()
  if(-not $code){ throw "No se recibió código de Spotify." }
  $body = @{
    grant_type    = "authorization_code"; code = $code
    redirect_uri  = $redirectUri; client_id = $clientId; client_secret = $clientSecret
  }
  Write-Info "Obteniendo token..."
  $token = Invoke-RestMethod -Uri "https://accounts.spotify.com/api/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
  $token | ConvertTo-Json | Out-File -Encoding utf8 $tokenFile
  return $token
}

Function Refresh-AccessToken($rt) {
  $body = @{ grant_type="refresh_token"; refresh_token=$rt; client_id=$clientId; client_secret=$clientSecret }
  Write-Info "♻ Refrescando token..."
  $t = Invoke-RestMethod -Uri "https://accounts.spotify.com/api/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
  if(-not $t.refresh_token){ $t | Add-Member -NotePropertyName refresh_token -NotePropertyValue $rt }
  $t | ConvertTo-Json | Out-File -Encoding utf8 $tokenFile
  return $t
}

Function Get-AccessToken {
  if (Test-Path $tokenFile) {
    $saved = Get-Content $tokenFile -Raw | ConvertFrom-Json
    if ($saved.refresh_token -and $saved.access_token) {
      return (Refresh-AccessToken $saved.refresh_token)
    }
  }
  return (Start-AuthFlow)
}

Function Invoke-SpotifyApi([string]$m,[string]$u,[hashtable]$h,$B=$null,[string]$ct="application/json") {
  try {
    return Invoke-RestMethod -Method $m -Uri $u -Headers $h -ContentType $ct -Body $B
  } catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 401) {
      $t = Refresh-AccessToken $global:RefreshToken
      $global:AccessToken = $t.access_token; $global:RefreshToken = $t.refresh_token
      $h.Authorization = "Bearer $global:AccessToken"
      return Invoke-RestMethod -Method $m -Uri $u -Headers $h -ContentType $ct -Body $B
    } else { throw }
  }
}

$TargetPlaylists = @(
  @{Name="Hip Hop"; Id="6o874za9wYEGYjnDmEUUOS"},
  @{Name="Reggaetón - Descubrimiento Semanal"; Id="3awu4mw7SrBB6E3KI2WNht"},
  @{Name="Reggaetón - Streaming"; Id="2T90gDsTF3oEkJnSmFmXgi"},
  @{Name="Reggaetón Caliente"; Id="1MtwULwpMrUsa48z98IuRs"},
  @{Name="Pop"; Id="2f9DcOIlBilYTZOQGPoNjm"},
  @{Name="Rock"; Id="1I45Y1VzLSIa8S5W6opf6b"},
  @{Name="Cumbia"; Id="6ICL6i6vtQACRNNgH9AnGV"},
  @{Name="Viral"; Id="31jCLqKfsz7pNDeUGV9d9K"},
  @{Name="Nueva Ola"; Id="1ptHc2LriM8u6rAxaMwSeh"},
  @{Name="Género Versátil"; Id="4lEuBCAFXy2ORrqPTVOajX"},
  @{Name="Hits Globales (copia)"; Id="4lEuBCAFXy2ORrqPTVOajX"}
)

$ArtistId_Piolin = "4ft2U0hfKmlpKGxpb1fxkw"

Function Get-PiolinTracks([string]$Market="CL") {
  $h = @{ Authorization="Bearer $global:AccessToken" }
  $top = Invoke-SpotifyApi "GET" "https://api.spotify.com/v1/artists/$ArtistId_Piolin/top-tracks?market=$Market" $h
  $uris = @(); if ($top.tracks) { $uris = $top.tracks.uri }
  $alb = Invoke-SpotifyApi "GET" "https://api.spotify.com/v1/artists/$ArtistId_Piolin/albums?include_groups=single,album&limit=10&market=$Market" $h
  foreach($a in $alb.items) {
    $tr = Invoke-SpotifyApi "GET" "https://api.spotify.com/v1/albums/$($a.id)/tracks?limit=50&market=$Market" $h
    if ($tr.items) { $uris += $tr.items.uri }
  }
  return $uris | Select-Object -Unique
}

Function Get-CurrentUser {
  $h = @{ Authorization="Bearer $global:AccessToken" }
  return Invoke-SpotifyApi "GET" "https://api.spotify.com/v1/me" $h
}

Function Ensure-EditablePlaylist($pid,$name,$uid) {
  $h = @{ Authorization="Bearer $global:AccessToken" }
  $pl = Invoke-SpotifyApi "GET" "https://api.spotify.com/v1/playlists/$pid" $h
  if ($pl.owner.id -eq $uid) { return $pid }
  Write-Warn "No editable: '$($pl.name)'. Creando copia..."
  $body = @{ name="Auto - $name"; description="Curada IA Piolín RBA"; public=$false } | ConvertTo-Json
  $new = Invoke-SpotifyApi "POST" "https://api.spotify.com/v1/users/$uid/playlists" $h $body
  return $new.id
}

Function Get-PlaylistTrackUris($pid) {
  $h = @{ Authorization="Bearer $global:AccessToken" }
  $uris = @(); $limit=100; $off=0
  do {
    $url = "https://api.spotify.com/v1/playlists/$pid/tracks?fields=items(track(uri)),next&limit=$limit&offset=$off"
    $resp = Invoke-SpotifyApi "GET" $url $h
    $uris += ($resp.items | ForEach-Object { $_.track.uri })
    $off += $limit
  } while ($resp.next)
  return $uris | Select-Object -Unique
}

Function Add-TracksToPlaylist($pid,$uris) {
  if (-not $uris -or $uris.Count -eq 0) { return }
  $h = @{ Authorization="Bearer $global:AccessToken" }
  $chunkSize = 100
  for ($i=0; $i -lt $uris.Count; $i += $chunkSize) {
    $chunk = $uris[$i..([Math]::Min($i+$chunkSize-1,$uris.Count-1))]
    $body = @{ uris=$chunk } | ConvertTo-Json
    Invoke-SpotifyApi "POST" "https://api.spotify.com/v1/playlists/$pid/tracks" $h $body
    Start-Sleep -Milliseconds 200
  }
}

# ==== Run script ====
$token = Get-AccessToken; $global:AccessToken=$token.access_token; $global:RefreshToken=$token.refresh_token
Write-Good "Autenticación exitosa."
$me = Get-CurrentUser; $userId=$me.id; Write-Info "En cuenta: $($me.display_name) ($userId)"

$piolinUris = Get-PiolinTracks "CL"
Write-Info "Recolectadas $($piolinUris.Count) URIs únicas de Piolín RBA."

foreach($p in $TargetPlaylists | Select-Object -Unique Id,Name) {
  try {
    $eid = Ensure-EditablePlaylist $p.Id $p.Name $userId
    $existing = Get-PlaylistTrackUris $eid
    $toAdd = $piolinUris | Where-Object { $_ -and ($existing -notcontains $_) }
    if ($toAdd.Count -gt 0) {
      Add-TracksToPlaylist $eid $toAdd
      Write-Good "Agregadas $($toAdd.Count) canciones a '$($p.Name)'."
    } else {
      Write-Info "Nada nuevo para '$($p.Name)'. Ya estaban."
    }
  } catch { Write-Err "Error en '$($p.Name)': $($_.Exception.Message)" }
}
Write-Good "¡Proceso completado!"
