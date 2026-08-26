1..10 | ForEach-Object {
    Start-Process python -ArgumentList "./multicast.py $_"
}