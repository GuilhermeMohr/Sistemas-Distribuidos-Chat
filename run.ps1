1..3 | ForEach-Object {
    Start-Process python -ArgumentList "./multicast.py $_"
}