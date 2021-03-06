# Copyright (C) Microsoft Corporation. All rights reserved.
# Licensed under the MIT license. See LICENSE.txt in the project root for license information.

[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Configuration = $env:CONFIGURATION,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Platform = $env:PLATFORM,

    [Parameter()]
    [ValidateSet('Unit', 'Integration')]
    [string[]] $Type = @('Unit', 'Integration')
)

if (-not $Configuration) {
    $Configuration = 'Debug'
}

if (-not $Platform) {
    $Platform = 'x86'
}

[bool] $Failed = $false

if ($Type -contains 'Unit')
{
    # Find vstest.console.exe.
    $cmd = get-command vstest.console.exe -ea SilentlyContinue | select-object -expand Path
    if (-not $cmd) {
        $vswhere = get-childitem "$PSScriptRoot\..\packages\vswhere*" -filter vswhere.exe -recurse | select-object -first 1 -expand FullName
        if (-not $vswhere) {
            write-error 'Please run "nuget restore" on the solution to download vswhere.'
            exit 1
        }

        $path = & $vswhere -latest -requires Microsoft.VisualStudio.Component.ManagedDesktop.Core -property installationPath
        if (-not $path) {
            write-error 'No instance of Visual Studio found with vstest.console.exe. Please start a developer command prompt.'
            exit 1
        }

        $cmd = join-path $path 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe'
    }

    if (-not (test-path $cmd)) {
        write-error 'Could not find vstest.console.exe. Please start a developer command prompt.'
        exit 1
    }

    # Set up logger for AppVeyor.
    $logger = if ($env:APPVEYOR -eq 'true') {
        write-verbose 'Using AppVeyor logger when running in an AppVeyor build.'
        '/logger:appveyor'
    }

    # Discover test assemblies for the current configuration.
    $assemblies = get-childitem test -include *.test.dll -recurse | where-object {
        $_.fullname -match "\\bin\\$Configuration\\"
    } | foreach-object {
        [string] $path = $_.FullName

        write-verbose "Discovered test assembly '$path'."
        "$path"
    }

    # Run unit tests.
    & $cmd $logger $assemblies /parallel /platform:$Platform
    if (-not $?) {
        $Failed = $true
    }
}

if ($Type -contains 'Integration')
{
    # Run docker integration tests.
    if (get-command docker-compose -ea SilentlyContinue) {
        [string] $path = if ($env:APPVEYOR -eq 'true') {
            $no_tty = '-T'
            resolve-path "$PSScriptRoot\..\docker\appveyor\docker-compose.yml"
        } else {
            resolve-path "$PSScriptRoot\..\docker\docker-compose.yml"
        }

        $verbose = if ($VerbosePreference -eq 'Continue') {
            '--verbose'
        }

        # Set environment variables based on parameters so docker-compose uses them (-e doesn't seem to work on Windows).
        $OldConfiguration = $env:CONFIGURATION
        $env:CONFIGURATION = $Configuration

        $OldPlatform = $env:PLATFORM
        $env:PLATFORM = $Platform

        write-verbose "Running tests in '$path'"
        try {
            docker-compose -f "$path" $verbose run $no_tty --rm test -c Invoke-Pester C:\Tests -EnableExit -OutputFile C:\Tests\Results.xml -OutputFormat NUnitXml
            if (-not $?) {
                $Failed = $true
            }
        } finally {
            $env:CONFIGURATION = $OldConfiguration
            $env:PLATFORM = $OldPlatform
        }

        if ($env:APPVEYOR_JOB_ID) {
            [string] $path = resolve-path "$PSScriptRoot\..\docker\Tests\Results.xml"
            $url = "https://ci.appveyor.com/api/testresults/nunit/${env:APPVEYOR_JOB_ID}"

            write-verbose "Uploading '$path' to '$url'"
            $wc = new-object System.Net.WebClient
            $wc.UploadFile($url, $path)
        }
    }

    if ($Failed) {
        exit 1
    }
}

<#
.SYNOPSIS
Runs unit and integration tests.

.DESCRIPTION
Use this script to run unit and integration tests on this project.
You can also run one or the other using the -Type parameter.

When run in AppVeyor, test results will be posted to the run.

.PARAMETER Configuration
Set the build configuration. Defaults to the $env:CONFIGURATION environment variable;
otherwise, "Debug" if the environment variable is not set.

.PARAMETER Platform
Set the build platform. Defaults to the $env:PLATFORM environment variable;
otherwise, "x86" if the environment variable is not set.

.PARAMETER Type
Specify the type of tests to run. Values include "unit" and "integration".

.EXAMPLE
tools\test.ps1 -configuration release -type integration -v

This will run integration tests using the release binaries (if built) with verbose output.
#>
