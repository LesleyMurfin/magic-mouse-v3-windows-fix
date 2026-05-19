@{
    ExcludeRules = @(
        # Write-Host is intentional in interactive installer scripts — colored console
        # output is the correct UX pattern for a user-facing driver installer.
        'PSAvoidUsingWriteHost',

        # Internal helper functions (Stop-, Remove-, Set-) are not exported cmdlets
        # and do not need -WhatIf/-Confirm ShouldProcess support.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
