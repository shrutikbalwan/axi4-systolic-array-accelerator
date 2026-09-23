$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    Write-Host "== Python syntax and ML/reference regression =="
    $pyFiles = @(Get-ChildItem ml,sim -Filter *.py -File | ForEach-Object { $_.FullName })
    python -m py_compile $pyFiles
    python -m unittest discover -s ml -p 'test_*.py'

    Write-Host "== C driver compile =="
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    if ($null -ne $gcc) {
        $obj = Join-Path $env:TEMP "axi4_accelerator_driver_test.o"
        gcc -std=c11 -Wall -Wextra -Werror -Isw -c sw/test_compile.c -o $obj
        Write-Host "C headers compile cleanly"
    } else {
        Write-Warning "GCC unavailable; C compile skipped"
    }

    Write-Host "== OpenLane configuration validation =="
    python -c "import json; json.load(open('openlane/config.json')); json.load(open('openlane/config_tiled_axi4_gemm.json')); print('OpenLane JSON valid')"

    Write-Host "== HDL tool availability =="
    foreach ($tool in @('verilator', 'iverilog', 'yosys', 'sby', 'make')) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($null -ne $found) {
            Write-Host "$tool available: $($found.Source)"
        } else {
            Write-Warning "$tool unavailable; HDL lint/simulation/synthesis/formal remain CI-only"
        }
    }
    Write-Host "Reference checks passed"
}
finally {
    Pop-Location
}
