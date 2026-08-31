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

    . Import-ScriptFunction (Join-Path $PSScriptRoot "specs.ps1") "Get-VendorColor"
    . Import-ScriptFunction (Join-Path $PSScriptRoot "specs-price.ps1") "Get-ApproximatePrice"
}

Describe "specs vendor colors" {
    It "maps common component vendors to distinct colors" {
        Get-VendorColor "AMD Ryzen" | Should -Be ([ConsoleColor]::Red)
        Get-VendorColor "Intel Core" | Should -Be ([ConsoleColor]::Blue)
        Get-VendorColor "NVIDIA GeForce RTX" | Should -Be ([ConsoleColor]::Green)
        Get-VendorColor "Samsung SSD" | Should -Be ([ConsoleColor]::Cyan)
        Get-VendorColor "Unknown Device" | Should -Be ([ConsoleColor]::White)
    }
}

Describe "specs price lookup" {
    It "parses the first visible Newegg result price" {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '<li class="price-current">$<strong>1,249</strong><sup>.99</sup></li>'
            }
        }

        Get-ApproximatePrice "Example component" | Should -Be ([decimal]1249.99)
    }

    It "returns no price when the request fails" {
        Mock Invoke-WebRequest { throw "offline" }

        Get-ApproximatePrice "Example component" | Should -BeNullOrEmpty
    }
}
