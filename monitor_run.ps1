$RunID = "28911045611"
$Repo = "ygao9999/neovim_static"
$Url = "https://api.github.com/repos/$Repo/actions/runs/$RunID"

Write-Host "Monitoring run $RunID..."

while ($true) {
    $response = curl.exe -s $Url | ConvertFrom-Json
    $status = $response.status
    $conclusion = $response.conclusion

    if ($status -eq "completed") {
        Write-Host "Run completed with conclusion: $conclusion"
        if ($conclusion -ne "success") {
            Write-Host "Fetching logs for failed run..."
            $jobsUrl = "https://api.github.com/repos/$Repo/actions/runs/$RunID/jobs"
            $jobs = curl.exe -s $jobsUrl | ConvertFrom-Json
            
            foreach ($job in $jobs.jobs) {
                if ($job.conclusion -eq "failure") {
                    Write-Host "Failed job: $($job.name)"
                    # We can't download logs easily without auth if it's not fully public, but actions logs are public for public repos
                    $logUrl = "https://api.github.com/repos/$Repo/actions/jobs/$($job.id)/logs"
                    Write-Host "Downloading log from: $logUrl"
                    # curl -L handles redirects
                    curl.exe -s -L $logUrl -o "job_$($job.id).log"
                    Write-Host "--- LAST 500 LINES OF FAILED JOB LOG ---"
                    Get-Content "job_$($job.id).log" -Tail 500
                    Write-Host "------------------------------------------"
                }
            }
        }
        break
    }
    
    Start-Sleep -Seconds 20
}
