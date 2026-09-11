BeforeAll {
    function Import-ScriptFunction {
        param([string]$Path, [string]$Name)

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $scriptPath = Join-Path $PSScriptRoot "specs-price.ps1"
    . Import-ScriptFunction $scriptPath "Get-SingleSourcePrice"
    . Import-ScriptFunction $scriptPath "ConvertFrom-ComparisonDate"
}

Describe "regional price parsing" {
    It "parses US-style prices" {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ Content = 'class="a-offscreen">$1,249.99<' }
        }
        $source = [pscustomobject]@{
            Name = "Amazon US"; Uri = "https://example.test/?q={0}"
            PriceRegex = 'class="a-offscreen">\$(?<price>[\d,]+\.\d{2})<'
            Culture = "en-US"; AcceptLanguage = "en-US"
        }

        (Get-SingleSourcePrice $source "GPU" @{}).Price | Should -Be ([decimal]1249.99)
    }

    It "parses EU-style prices" {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ Content = "class=`"a-offscreen`">1.234,56 $([char]0x20AC)<" }
        }
        $source = [pscustomobject]@{
            Name = "Amazon Germany"; Uri = "https://example.test/?q={0}"
            PriceRegex = 'class="a-offscreen">(?<price>[\d.]+,\d{2})\s*\u20AC<'
            Culture = "de-DE"; AcceptLanguage = "de-DE"
        }

        (Get-SingleSourcePrice $source "GPU" @{}).Price | Should -Be ([decimal]1234.56)
    }
}

Describe "comparison date parsing" {
    It "accepts padded and unpadded DD/MM/YYYY dates" {
        @("01/09/2025", "1/9/2025", "1/09/2025", "01/9/2025") | ForEach-Object {
            (ConvertFrom-ComparisonDate $_).ToString("yyyy-MM-dd") | Should -Be "2025-09-01"
        }
    }

    It "rejects impossible dates" {
        ConvertFrom-ComparisonDate "30/02/2025" | Should -BeNullOrEmpty
    }
}
