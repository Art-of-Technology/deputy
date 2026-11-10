@{
    # The exact module versions Deputy's own gate runs on. Invoke-Lint.ps1 and
    # Invoke-Tests.ps1 import these versions and nothing else, so a local run,
    # the Deputy's no-mistakes gate and CI all judge a branch with the same
    # rules. Install them with tools\Install-GateModules.ps1; CI keys its module
    # cache on this file, so bumping a version here is the whole upgrade.
    PSScriptAnalyzer = '1.25.0'
    Pester           = '5.7.1'
}
