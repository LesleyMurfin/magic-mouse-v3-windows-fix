@{
    ExcludeRules = @(
        # Write-Host is intentional in interactive installer scripts — colored console
        # output is the correct UX pattern for a user-facing driver installer.
        'PSAvoidUsingWriteHost',

        # Internal helper functions (Stop-, Remove-, Set-) are not exported cmdlets
        # and do not need -WhatIf/-Confirm ShouldProcess support.
        'PSUseShouldProcessForStateChangingFunctions',

        # This rule's naive English pluralisation misfires on the Windows nouns this
        # repo is built around, and it offers no allow-list to spell the exceptions:
        #   * 'Sys' is the .sys driver-file extension (Find-KmdfSys, Backup-KmdfLiveSys)
        #   * 'Program Files' is a literal Windows directory name
        #   * 'LowerFilters' is a literal registry value name
        #   * 'Caps' is the HIDP_CAPS structure (Get-HidCaps)
        # Renaming to satisfy it would make these helpers describe Windows less
        # accurately, so the rule is off rather than the names being wrong.
        'PSUseSingularNouns'
    )

    Rules = @{
        # Pin the built-in cmdlet inventory to Windows PowerShell 5.1, which is what
        # actually runs these installers (they are launched by powershell.exe from
        # .cmd wrappers and scheduled tasks). The analyser otherwise defaults to its
        # 'core-6.1.0-windows' profile, whose PSDesiredStateConfiguration entry
        # carries a stray private helper -- Write-Log, listed as CommandType Function
        # at version 0.0 -- that is not a real PowerShell cmdlet and never shipped as
        # one. Comparing against the 5.1 inventory drops that phantom while keeping
        # the rule live for genuine shadowing of real cmdlets.
        PSAvoidOverwritingBuiltInCmdlets = @{
            PowerShellVersion = @('desktop-5.1.14393.206-windows')
        }
    }
}
