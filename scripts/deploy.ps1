<#
.SYNOPSIS
  Packages the nested templates to S3 and deploys/updates one environment.

.EXAMPLE
  ./scripts/deploy.ps1 -Environment sandbox
  ./scripts/deploy.ps1 -Environment prod -AwsProfile nls-prod
  ./scripts/deploy.ps1 -Environment sandbox -ValidateOnly
#>
[CmdletBinding()]
param(
    # Name of a file in ./params (without .json)
    [Parameter(Mandatory = $true)][string]$Environment,
    # Overrides the Region in the params file
    [string]$Region,
    # AWS CLI named profile (optional)
    [string]$AwsProfile,
    # S3 bucket for packaged templates; defaults to cfn-artifacts-<account>-<region>
    [string]$ArtifactBucket,
    # Only lint/validate templates, do not deploy
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $root "params/$Environment.json"
if (-not (Test-Path $configPath)) { throw "Parameter file not found: $configPath" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json

if (-not $Region) { $Region = $config.Region }
$stackName = $config.StackName
$awsArgs = @('--region', $Region)
if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }

function Invoke-Aws {
    & aws @args @awsArgs
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

Write-Host "Validating templates..." -ForegroundColor Cyan
Get-ChildItem (Join-Path $root 'templates') -Filter *.yaml | ForEach-Object {
    Invoke-Aws cloudformation validate-template --template-body "file://$($_.FullName)" --output text --query 'Description' | Out-Null
    Write-Host "  OK  $($_.Name)"
}
if ($ValidateOnly) { return }

$account = Invoke-Aws sts get-caller-identity --query Account --output text
if (-not $ArtifactBucket) { $ArtifactBucket = "cfn-artifacts-$account-$Region" }

& aws s3api head-bucket --bucket $ArtifactBucket @awsArgs 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating artifact bucket $ArtifactBucket" -ForegroundColor Cyan
    Invoke-Aws s3 mb "s3://$ArtifactBucket"
    Invoke-Aws s3api put-public-access-block --bucket $ArtifactBucket `
        --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
}

$buildDir = Join-Path $root '.build'
New-Item -ItemType Directory -Force $buildDir | Out-Null
$packaged = Join-Path $buildDir "$stackName.packaged.yaml"

Write-Host "Packaging templates to s3://$ArtifactBucket/$stackName/" -ForegroundColor Cyan
Invoke-Aws cloudformation package `
    --template-file (Join-Path $root 'templates/main.yaml') `
    --s3-bucket $ArtifactBucket `
    --s3-prefix $stackName `
    --output-template-file $packaged | Out-Null

$overrides = $config.Parameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }
$tags = $config.Tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }

Write-Host "Deploying stack $stackName to $Region (this takes ~10-15 min, longer with RDS)..." -ForegroundColor Cyan
Invoke-Aws cloudformation deploy `
    --template-file $packaged `
    --stack-name $stackName `
    --s3-bucket $ArtifactBucket `
    --s3-prefix $stackName `
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM `
    --no-fail-on-empty-changeset `
    --parameter-overrides @overrides `
    --tags @tags

Invoke-Aws cloudformation describe-stacks --stack-name $stackName `
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
