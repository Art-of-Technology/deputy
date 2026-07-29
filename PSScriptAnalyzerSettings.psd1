@{
    # Lint gate for bin\: run with
    #   Invoke-ScriptAnalyzer -Path bin\*.ps1 -Settings PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Internal script helpers, not exported module cmdlets: ShouldProcess
        # plumbing and singular-noun naming add ceremony without value here.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
}
