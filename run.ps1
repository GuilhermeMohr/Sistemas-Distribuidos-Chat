# Launcher configurável — sobe N nós sem alterar o código (R3).
# Gera nos.json com N nós e inicia N processos.
#   .\run.ps1 -Nodes 3
#   .\run.ps1 -Nodes 8
#   .\run.ps1 -Nodes 15
param(
    [int]$Nodes = 3,
    [string]$Group = "239.0.0.1",
    [int]$Port = 50000
)

$nodeList = 1..$Nodes | ForEach-Object {
    [ordered]@{ id = "$_"; host = "127.0.0.1" }
}
$config = [ordered]@{
    multicast = [ordered]@{ group = $Group; port = $Port }
    nodes     = @($nodeList)
}
$config | ConvertTo-Json -Depth 5 | Set-Content -Path "./nos.json" -Encoding utf8
Write-Host "nos.json gerado com $Nodes nós."

1..$Nodes | ForEach-Object {
    Start-Process python -ArgumentList "./multicast.py $_"
}
