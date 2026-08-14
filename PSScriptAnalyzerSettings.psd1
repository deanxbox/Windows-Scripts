@{
    # These scripts intentionally target PowerShell 7 and render interactive,
    # colorized console output.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseBOMForUnicodeEncodedFile'
    )
    Severity = @('Error', 'Warning')
}
