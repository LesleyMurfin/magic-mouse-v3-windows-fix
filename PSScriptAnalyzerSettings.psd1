@{
    ExcludeRules = @(
        # Write-Host is intentional in interactive installer scripts — colored console
        # output is the correct UX pattern for a user-facing driver installer.
        'PSAvoidUsingWriteHost'
    )
}
