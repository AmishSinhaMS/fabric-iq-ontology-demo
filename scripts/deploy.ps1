<#
.SYNOPSIS
    End-to-end deployment of the Fabric IQ Ontology tutorial (Lakeshore Retail).

.DESCRIPTION
    This script automates the complete Microsoft Fabric Ontology (Preview) tutorial:
      1. Creates a workspace with capacity assignment
      2. Creates a Lakehouse and loads 4 CSV files as delta tables
      3. Creates a Direct Lake semantic model with relationships
      4. Creates an Eventhouse with KQL database and ingests telemetry data
      5. Creates an Ontology with 4 entity types, bindings, and relationships
      6. Creates a Data Agent with AI instructions

.PARAMETER WorkspaceName
    Name for the Fabric workspace (default: "cloud_FabricIQ Demo")

.PARAMETER CapacityId
    Fabric capacity ID to assign. If not provided, lists available capacities.

.EXAMPLE
    .\deploy.ps1 -WorkspaceName "MyOntologyDemo" -CapacityId "ba27f939-..."

.NOTES
    Prerequisites:
      - Azure CLI installed and authenticated (az login)
      - Fabric capacity (F2+) available
      - Ontology preview tenant settings enabled
#>

param(
    [string]$WorkspaceName = "cloud_FabricIQ Demo",
    [string]$CapacityId = ""
)

$ErrorActionPreference = "Stop"
$DataPath = Join-Path $PSScriptRoot "..\data"

# ─── Helper Functions ──────────────────────────────────────────────────────────

function Get-FabricToken {
    return az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
}

function Get-StorageToken {
    return az account get-access-token --resource "https://storage.azure.com" --query accessToken -o tsv
}

function Get-KustoToken {
    return az account get-access-token --resource "https://kusto.kusto.windows.net" --query accessToken -o tsv
}

function Get-PowerBIToken {
    return az account get-access-token --resource "https://analysis.windows.net/powerbi/api" --query accessToken -o tsv
}

function Get-FabricHeaders {
    $token = Get-FabricToken
    return @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
}

function Wait-ForOperation {
    param([string]$OperationId, [int]$MaxWaitSeconds = 300)
    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        Start-Sleep -Seconds 10
        $elapsed += 10
        $headers = Get-FabricHeaders
        $status = Invoke-RestMethod -Method GET `
            -Uri "https://api.fabric.microsoft.com/v1/operations/$OperationId" `
            -Headers $headers
        Write-Host "  [$elapsed`s] Status: $($status.status)" -NoNewline
        if ($status.percentComplete) { Write-Host " ($($status.percentComplete)%)" } else { Write-Host "" }

        if ($status.status -eq "Succeeded") { return $true }
        if ($status.status -eq "Failed") {
            Write-Host "  ERROR: $($status.error | ConvertTo-Json -Depth 5)" -ForegroundColor Red
            return $false
        }
    }
    Write-Host "  TIMEOUT after $MaxWaitSeconds seconds" -ForegroundColor Yellow
    return $false
}

function ToBase64([string]$text) {
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
}

# ─── Phase 1: Workspace & Capacity ────────────────────────────────────────────

Write-Host "`n═══ PHASE 1: Create Workspace ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

$body = @{ displayName = $WorkspaceName } | ConvertTo-Json
$ws = Invoke-RestMethod -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces" `
    -Headers $headers -Body $body
$workspaceId = $ws.id
Write-Host "  Workspace: $($ws.displayName) ($workspaceId)" -ForegroundColor Green

if (-not $CapacityId) {
    Write-Host "  Available capacities:" -ForegroundColor Yellow
    $caps = Invoke-RestMethod -Method GET -Uri "https://api.fabric.microsoft.com/v1/capacities" -Headers $headers
    $activeCaps = $caps.value | Where-Object { $_.state -eq "Active" }
    $activeCaps | ForEach-Object { Write-Host "    $($_.displayName) ($($_.id)) SKU: $($_.sku)" }
    $CapacityId = ($activeCaps | Select-Object -First 1).id
    Write-Host "  Auto-selected: $CapacityId" -ForegroundColor Yellow
}

$capBody = @{ capacityId = $CapacityId } | ConvertTo-Json
Invoke-RestMethod -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/assignToCapacity" `
    -Headers $headers -Body $capBody
Write-Host "  Capacity assigned: $CapacityId" -ForegroundColor Green

# ─── Phase 2: Lakehouse & Data ────────────────────────────────────────────────

Write-Host "`n═══ PHASE 2: Create Lakehouse & Load Data ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

$lhBody = @{ displayName = "OntologyDataLH"; type = "Lakehouse" } | ConvertTo-Json
$lh = Invoke-RestMethod -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" `
    -Headers $headers -Body $lhBody
$lakehouseId = $lh.id
Write-Host "  Lakehouse: $lakehouseId" -ForegroundColor Green

# Upload CSV files via OneLake DFS API
$storageToken = Get-StorageToken
$csvFiles = @("DimStore.csv", "DimProducts.csv", "FactSales.csv", "Freezer.csv")

foreach ($file in $csvFiles) {
    $filePath = Join-Path $DataPath $file
    $onelakePath = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$lakehouseId/Files/$file"
    $uploadHeaders = @{ "Authorization" = "Bearer $storageToken" }

    Invoke-RestMethod -Method PUT -Uri "$onelakePath`?resource=file" -Headers $uploadHeaders
    $content = [System.IO.File]::ReadAllBytes($filePath)
    $uploadHeaders["Content-Type"] = "application/octet-stream"
    $uploadHeaders["Content-Length"] = $content.Length
    Invoke-RestMethod -Method PATCH -Uri "$onelakePath`?position=0&action=append" `
        -Headers $uploadHeaders -Body $content
    Invoke-RestMethod -Method PATCH -Uri "$onelakePath`?position=$($content.Length)&action=flush" `
        -Headers @{ "Authorization" = "Bearer $storageToken" }
    Write-Host "  Uploaded: $file" -ForegroundColor Green
}

# Load CSVs to delta tables
$headers = Get-FabricHeaders
$filesToTables = @{
    "DimStore.csv" = "dimstore"
    "DimProducts.csv" = "dimproducts"
    "FactSales.csv" = "factsales"
    "Freezer.csv" = "freezer"
}

$loadOps = @{}
foreach ($entry in $filesToTables.GetEnumerator()) {
    $loadBody = @{
        relativePath = "Files/$($entry.Key)"
        pathType = "File"
        mode = "Overwrite"
        formatOptions = @{ format = "Csv"; header = $true; delimiter = "," }
    } | ConvertTo-Json -Depth 5

    $response = Invoke-WebRequest -Method POST `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/lakehouses/$lakehouseId/tables/$($entry.Value)/load" `
        -Headers $headers -Body $loadBody
    Write-Host "  Loading table: $($entry.Value)" -ForegroundColor Green
}

Write-Host "  Waiting for table loads..." -ForegroundColor Yellow
Start-Sleep -Seconds 30
Write-Host "  All tables loaded" -ForegroundColor Green

# Get SQL endpoint details
$lhDetails = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/lakehouses/$lakehouseId" `
    -Headers $headers
$sqlServer = $lhDetails.properties.sqlEndpointProperties.connectionString
$sqlEndpointId = $lhDetails.properties.sqlEndpointProperties.id
Write-Host "  SQL Endpoint: $sqlServer" -ForegroundColor Green

# ─── Phase 3: Semantic Model ──────────────────────────────────────────────────

Write-Host "`n═══ PHASE 3: Create Semantic Model ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

$pbismContent = '{"version":"1.0"}'
$bimJson = @"
{
  "compatibilityLevel": 1604,
  "model": {
    "culture": "en-US",
    "defaultPowerBIDataSourceVersion": "powerBI_V3",
    "tables": [
      {
        "name": "dimproducts",
        "lineageTag": "11111111-1111-1111-1111-111111111111",
        "columns": [
          {"name":"ProductId","dataType":"string","sourceColumn":"ProductId","summarizeBy":"none","lineageTag":"11111111-1111-1111-1111-111111111112"},
          {"name":"ProductName","dataType":"string","sourceColumn":"ProductName","summarizeBy":"none","lineageTag":"11111111-1111-1111-1111-111111111113"},
          {"name":"Category","dataType":"string","sourceColumn":"Category","summarizeBy":"none","lineageTag":"11111111-1111-1111-1111-111111111114"},
          {"name":"Subcategory","dataType":"string","sourceColumn":"Subcategory","summarizeBy":"none","lineageTag":"11111111-1111-1111-1111-111111111115"},
          {"name":"Brand","dataType":"string","sourceColumn":"Brand","summarizeBy":"none","lineageTag":"11111111-1111-1111-1111-111111111116"}
        ],
        "partitions": [{"name":"part0","mode":"directLake","source":{"type":"entity","entityName":"dimproducts","schemaName":"dbo","expressionSource":"DatabaseQuery"}}]
      },
      {
        "name": "dimstore",
        "lineageTag": "22222222-2222-2222-2222-222222222222",
        "columns": [
          {"name":"StoreId","dataType":"string","sourceColumn":"StoreId","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222223"},
          {"name":"StoreName","dataType":"string","sourceColumn":"StoreName","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222224"},
          {"name":"City","dataType":"string","sourceColumn":"City","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222225"},
          {"name":"Region","dataType":"string","sourceColumn":"Region","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222226"},
          {"name":"Latitude","dataType":"double","sourceColumn":"Latitude","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222227"},
          {"name":"Longitude","dataType":"double","sourceColumn":"Longitude","summarizeBy":"none","lineageTag":"22222222-2222-2222-2222-222222222228"}
        ],
        "partitions": [{"name":"part0","mode":"directLake","source":{"type":"entity","entityName":"dimstore","schemaName":"dbo","expressionSource":"DatabaseQuery"}}]
      },
      {
        "name": "factsales",
        "lineageTag": "33333333-3333-3333-3333-333333333333",
        "columns": [
          {"name":"SaleId","dataType":"int64","sourceColumn":"SaleId","summarizeBy":"none","lineageTag":"33333333-3333-3333-3333-333333333334"},
          {"name":"SaleDate","dataType":"string","sourceColumn":"SaleDate","summarizeBy":"none","lineageTag":"33333333-3333-3333-3333-333333333335"},
          {"name":"StoreId","dataType":"string","sourceColumn":"StoreId","summarizeBy":"none","lineageTag":"33333333-3333-3333-3333-333333333336"},
          {"name":"ProductId","dataType":"string","sourceColumn":"ProductId","summarizeBy":"none","lineageTag":"33333333-3333-3333-3333-333333333337"},
          {"name":"Units","dataType":"int64","sourceColumn":"Units","summarizeBy":"sum","lineageTag":"33333333-3333-3333-3333-333333333338"},
          {"name":"RevenueUSD","dataType":"double","sourceColumn":"RevenueUSD","summarizeBy":"sum","lineageTag":"33333333-3333-3333-3333-333333333339"}
        ],
        "partitions": [{"name":"part0","mode":"directLake","source":{"type":"entity","entityName":"factsales","schemaName":"dbo","expressionSource":"DatabaseQuery"}}]
      }
    ],
    "relationships": [
      {"name":"factsales_to_dimstore","fromTable":"factsales","fromColumn":"StoreId","toTable":"dimstore","toColumn":"StoreId"},
      {"name":"factsales_to_dimproducts","fromTable":"factsales","fromColumn":"ProductId","toTable":"dimproducts","toColumn":"ProductId"}
    ],
    "expressions": [
      {"name":"DatabaseQuery","kind":"m","expression":"let\n    database = Sql.Database(\"$sqlServer\", \"$sqlEndpointId\")\nin\n    database"}
    ]
  }
}
"@

$smParts = @(
    @{ path = "definition.pbism"; payload = (ToBase64 $pbismContent); payloadType = "InlineBase64" }
    @{ path = "model.bim"; payload = (ToBase64 $bimJson); payloadType = "InlineBase64" }
)

$smBody = @{
    displayName = "RetailSalesModel"; type = "SemanticModel"
    definition = @{ parts = $smParts }
} | ConvertTo-Json -Depth 10

$smResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" `
    -Headers $headers -Body $smBody
$smOpId = $smResponse.Headers["x-ms-operation-id"]
Write-Host "  Creating semantic model..." -ForegroundColor Yellow
Wait-ForOperation -OperationId $smOpId

$items = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" -Headers $headers
$semanticModelId = ($items.value | Where-Object { $_.type -eq "SemanticModel" }).id
Write-Host "  Semantic Model: $semanticModelId" -ForegroundColor Green

# ─── Phase 4: Eventhouse & KQL ────────────────────────────────────────────────

Write-Host "`n═══ PHASE 4: Create Eventhouse & Ingest Telemetry ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

$ehBody = @{ displayName = "TelemetryDataEH"; type = "Eventhouse" } | ConvertTo-Json
$eh = Invoke-RestMethod -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" `
    -Headers $headers -Body $ehBody
$eventhouseId = $eh.id
Write-Host "  Eventhouse: $eventhouseId" -ForegroundColor Green

Start-Sleep -Seconds 10

# Get KQL database details
$items = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" -Headers $headers
$kqlDb = $items.value | Where-Object { $_.type -eq "KQLDatabase" }
$kqlDbId = $kqlDb.id

$kqlDbDetails = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/kqlDatabases/$kqlDbId" `
    -Headers $headers
$kustoUri = $kqlDbDetails.properties.queryServiceUri
$kqlDbName = $kqlDbDetails.displayName
Write-Host "  KQL Database: $kqlDbName at $kustoUri" -ForegroundColor Green

# Create table and ingest data
$kustoToken = Get-KustoToken
$kustoHeaders = @{ "Authorization" = "Bearer $kustoToken"; "Content-Type" = "application/json" }

$createCmd = ".create table FreezerTelemetry (timestamp: datetime, storeId: string, freezerId: string, temperatureC: real, humidityPct: real, doorOpen: int)"
Invoke-RestMethod -Method POST -Uri "$kustoUri/v1/rest/mgmt" -Headers $kustoHeaders `
    -Body (@{ db = $kqlDbName; csl = $createCmd } | ConvertTo-Json)
Write-Host "  Table created: FreezerTelemetry" -ForegroundColor Green

$ingestCmd = @"
.ingest inline into table FreezerTelemetry <|
2025-08-01T10:00:00Z,S-PAR-01,F-PAR-01,-19.2,45.0,0
2025-08-01T10:05:00Z,S-PAR-01,F-PAR-01,-18.5,47.2,1
2025-08-01T10:10:00Z,S-PAR-01,F-PAR-01,-17.8,49.1,0
2025-08-02T09:55:00Z,S-BER-01,F-BER-02,-20.1,41.0,0
2025-08-03T11:20:00Z,S-AMS-01,F-AMS-03,-16.9,52.3,1
"@
Invoke-RestMethod -Method POST -Uri "$kustoUri/v1/rest/mgmt" -Headers $kustoHeaders `
    -Body (@{ db = $kqlDbName; csl = $ingestCmd } | ConvertTo-Json)
Write-Host "  Data ingested: 5 rows" -ForegroundColor Green

# ─── Phase 5: Ontology ────────────────────────────────────────────────────────

Write-Host "`n═══ PHASE 5: Create & Configure Ontology ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

# Create empty ontology
$ontBody = @{ displayName = "RetailSalesOntology"; type = "Ontology" } | ConvertTo-Json
$ontResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" `
    -Headers $headers -Body $ontBody
$ontOpId = $ontResponse.Headers["x-ms-operation-id"]
Write-Host "  Creating ontology..." -ForegroundColor Yellow
Wait-ForOperation -OperationId $ontOpId

$items = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" -Headers $headers
$ontologyId = ($items.value | Where-Object { $_.type -eq "Ontology" }).id
Write-Host "  Ontology: $ontologyId" -ForegroundColor Green

# Get the platform definition from the empty ontology
$headers = Get-FabricHeaders
$defResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/ontologies/$ontologyId/getDefinition" `
    -Headers $headers
$defOpId = $defResponse.Headers["x-ms-operation-id"]
Start-Sleep -Seconds 10
$defResult = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/operations/$defOpId/result" -Headers $headers
$platformB64 = ($defResult.definition.parts | Where-Object { $_.path -eq ".platform" }).payload

# Build ontology definition with entity types, bindings, and relationships
# (See docs/ontology-definition.md for the full schema explanation)

$storeJson = '{"id":"1000000000001","namespace":"usertypes","baseEntityTypeId":null,"name":"Store","entityIdParts":["2000000000001"],"displayNamePropertyId":"2000000000002","namespaceType":"Custom","visibility":"Visible","properties":[{"id":"2000000000001","name":"StoreId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000002","name":"StoreName","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000003","name":"City","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000004","name":"Region","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000005","name":"Latitude","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"},{"id":"2000000000006","name":"Longitude","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"}],"timeseriesProperties":[]}'
$productsJson = '{"id":"1000000000002","namespace":"usertypes","baseEntityTypeId":null,"name":"Products","entityIdParts":["2000000000010"],"displayNamePropertyId":"2000000000011","namespaceType":"Custom","visibility":"Visible","properties":[{"id":"2000000000010","name":"ProductId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000011","name":"ProductName","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000012","name":"Category","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000013","name":"Subcategory","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000014","name":"Brand","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"}],"timeseriesProperties":[]}'
$saleEventJson = '{"id":"1000000000003","namespace":"usertypes","baseEntityTypeId":null,"name":"SaleEvent","entityIdParts":["2000000000020"],"displayNamePropertyId":"2000000000020","namespaceType":"Custom","visibility":"Visible","properties":[{"id":"2000000000020","name":"SaleId","redefines":null,"baseTypeNamespaceType":null,"valueType":"BigInt"},{"id":"2000000000021","name":"SaleDate","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000022","name":"SaleStoreId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000023","name":"SaleProductId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000024","name":"Units","redefines":null,"baseTypeNamespaceType":null,"valueType":"BigInt"},{"id":"2000000000025","name":"RevenueUSD","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"}],"timeseriesProperties":[]}'
$freezerJson = '{"id":"1000000000004","namespace":"usertypes","baseEntityTypeId":null,"name":"Freezer","entityIdParts":["2000000000030"],"displayNamePropertyId":"2000000000030","namespaceType":"Custom","visibility":"Visible","properties":[{"id":"2000000000030","name":"FreezerId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000031","name":"FreezerModel","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"},{"id":"2000000000032","name":"minSafeTempC","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"},{"id":"2000000000033","name":"FreezerStoreId","redefines":null,"baseTypeNamespaceType":null,"valueType":"String"}],"timeseriesProperties":[{"id":"2000000000040","name":"tsTimestamp","redefines":null,"baseTypeNamespaceType":null,"valueType":"DateTime"},{"id":"2000000000041","name":"temperatureC","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"},{"id":"2000000000042","name":"humidityPct","redefines":null,"baseTypeNamespaceType":null,"valueType":"Double"},{"id":"2000000000043","name":"doorOpen","redefines":null,"baseTypeNamespaceType":null,"valueType":"BigInt"}]}'

$storeBindingJson = "{`"id`":`"a1a1a1a1-0001-0001-0001-a1a1a1a1a1a1`",`"dataBindingConfiguration`":{`"dataBindingType`":`"NonTimeSeries`",`"propertyBindings`":[{`"sourceColumnName`":`"StoreId`",`"targetPropertyId`":`"2000000000001`"},{`"sourceColumnName`":`"StoreName`",`"targetPropertyId`":`"2000000000002`"},{`"sourceColumnName`":`"City`",`"targetPropertyId`":`"2000000000003`"},{`"sourceColumnName`":`"Region`",`"targetPropertyId`":`"2000000000004`"},{`"sourceColumnName`":`"Latitude`",`"targetPropertyId`":`"2000000000005`"},{`"sourceColumnName`":`"Longitude`",`"targetPropertyId`":`"2000000000006`"}],`"sourceTableProperties`":{`"sourceType`":`"LakehouseTable`",`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"dimstore`",`"sourceSchema`":`"dbo`"}}}"
$productsBindingJson = "{`"id`":`"a1a1a1a1-0002-0002-0002-a1a1a1a1a1a1`",`"dataBindingConfiguration`":{`"dataBindingType`":`"NonTimeSeries`",`"propertyBindings`":[{`"sourceColumnName`":`"ProductId`",`"targetPropertyId`":`"2000000000010`"},{`"sourceColumnName`":`"ProductName`",`"targetPropertyId`":`"2000000000011`"},{`"sourceColumnName`":`"Category`",`"targetPropertyId`":`"2000000000012`"},{`"sourceColumnName`":`"Subcategory`",`"targetPropertyId`":`"2000000000013`"},{`"sourceColumnName`":`"Brand`",`"targetPropertyId`":`"2000000000014`"}],`"sourceTableProperties`":{`"sourceType`":`"LakehouseTable`",`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"dimproducts`",`"sourceSchema`":`"dbo`"}}}"
$saleEventBindingJson = "{`"id`":`"a1a1a1a1-0003-0003-0003-a1a1a1a1a1a1`",`"dataBindingConfiguration`":{`"dataBindingType`":`"NonTimeSeries`",`"propertyBindings`":[{`"sourceColumnName`":`"SaleId`",`"targetPropertyId`":`"2000000000020`"},{`"sourceColumnName`":`"SaleDate`",`"targetPropertyId`":`"2000000000021`"},{`"sourceColumnName`":`"StoreId`",`"targetPropertyId`":`"2000000000022`"},{`"sourceColumnName`":`"ProductId`",`"targetPropertyId`":`"2000000000023`"},{`"sourceColumnName`":`"Units`",`"targetPropertyId`":`"2000000000024`"},{`"sourceColumnName`":`"RevenueUSD`",`"targetPropertyId`":`"2000000000025`"}],`"sourceTableProperties`":{`"sourceType`":`"LakehouseTable`",`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"factsales`",`"sourceSchema`":`"dbo`"}}}"
$freezerStaticBindingJson = "{`"id`":`"a1a1a1a1-0004-0004-0004-a1a1a1a1a1a1`",`"dataBindingConfiguration`":{`"dataBindingType`":`"NonTimeSeries`",`"propertyBindings`":[{`"sourceColumnName`":`"FreezerId`",`"targetPropertyId`":`"2000000000030`"},{`"sourceColumnName`":`"Model`",`"targetPropertyId`":`"2000000000031`"},{`"sourceColumnName`":`"minSafeTempC`",`"targetPropertyId`":`"2000000000032`"},{`"sourceColumnName`":`"StoreId`",`"targetPropertyId`":`"2000000000033`"}],`"sourceTableProperties`":{`"sourceType`":`"LakehouseTable`",`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"freezer`",`"sourceSchema`":`"dbo`"}}}"
$freezerTsBindingJson = "{`"id`":`"a1a1a1a1-0005-0005-0005-a1a1a1a1a1a1`",`"dataBindingConfiguration`":{`"dataBindingType`":`"TimeSeries`",`"timestampColumnName`":`"timestamp`",`"propertyBindings`":[{`"sourceColumnName`":`"freezerId`",`"targetPropertyId`":`"2000000000030`"},{`"sourceColumnName`":`"timestamp`",`"targetPropertyId`":`"2000000000040`"},{`"sourceColumnName`":`"temperatureC`",`"targetPropertyId`":`"2000000000041`"},{`"sourceColumnName`":`"humidityPct`",`"targetPropertyId`":`"2000000000042`"},{`"sourceColumnName`":`"doorOpen`",`"targetPropertyId`":`"2000000000043`"}],`"sourceTableProperties`":{`"sourceType`":`"KustoTable`",`"workspaceId`":`"$workspaceId`",`"itemId`":`"$eventhouseId`",`"clusterUri`":`"$kustoUri`",`"databaseName`":`"$kqlDbName`",`"sourceTableName`":`"FreezerTelemetry`"}}}"

$soldRelJson = '{"namespace":"usertypes","id":"3000000000001","name":"sold","namespaceType":"Custom","source":{"entityTypeId":"1000000000003"},"target":{"entityTypeId":"1000000000002"}}'
$fromRelJson = '{"namespace":"usertypes","id":"3000000000002","name":"from_store","namespaceType":"Custom","source":{"entityTypeId":"1000000000003"},"target":{"entityTypeId":"1000000000001"}}'
$operatesRelJson = '{"namespace":"usertypes","id":"3000000000003","name":"operates","namespaceType":"Custom","source":{"entityTypeId":"1000000000001"},"target":{"entityTypeId":"1000000000004"}}'

$soldCtxJson = "{`"id`":`"b1b1b1b1-0001-0001-0001-b1b1b1b1b1b1`",`"dataBindingTable`":{`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"factsales`",`"sourceSchema`":`"dbo`",`"sourceType`":`"LakehouseTable`"},`"sourceKeyRefBindings`":[{`"sourceColumnName`":`"SaleId`",`"targetPropertyId`":`"2000000000020`"}],`"targetKeyRefBindings`":[{`"sourceColumnName`":`"ProductId`",`"targetPropertyId`":`"2000000000010`"}]}"
$fromCtxJson = "{`"id`":`"b1b1b1b1-0002-0002-0002-b1b1b1b1b1b1`",`"dataBindingTable`":{`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"factsales`",`"sourceSchema`":`"dbo`",`"sourceType`":`"LakehouseTable`"},`"sourceKeyRefBindings`":[{`"sourceColumnName`":`"SaleId`",`"targetPropertyId`":`"2000000000020`"}],`"targetKeyRefBindings`":[{`"sourceColumnName`":`"StoreId`",`"targetPropertyId`":`"2000000000001`"}]}"
$operatesCtxJson = "{`"id`":`"b1b1b1b1-0003-0003-0003-b1b1b1b1b1b1`",`"dataBindingTable`":{`"workspaceId`":`"$workspaceId`",`"itemId`":`"$lakehouseId`",`"sourceTableName`":`"freezer`",`"sourceSchema`":`"dbo`",`"sourceType`":`"LakehouseTable`"},`"sourceKeyRefBindings`":[{`"sourceColumnName`":`"StoreId`",`"targetPropertyId`":`"2000000000001`"}],`"targetKeyRefBindings`":[{`"sourceColumnName`":`"FreezerId`",`"targetPropertyId`":`"2000000000030`"}]}"

$ontParts = @(
    @{ path = ".platform"; payload = $platformB64; payloadType = "InlineBase64" }
    @{ path = "definition.json"; payload = "e30="; payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000001/definition.json"; payload = (ToBase64 $storeJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000002/definition.json"; payload = (ToBase64 $productsJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000003/definition.json"; payload = (ToBase64 $saleEventJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000004/definition.json"; payload = (ToBase64 $freezerJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000001/DataBindings/a1a1a1a1-0001-0001-0001-a1a1a1a1a1a1.json"; payload = (ToBase64 $storeBindingJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000002/DataBindings/a1a1a1a1-0002-0002-0002-a1a1a1a1a1a1.json"; payload = (ToBase64 $productsBindingJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000003/DataBindings/a1a1a1a1-0003-0003-0003-a1a1a1a1a1a1.json"; payload = (ToBase64 $saleEventBindingJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000004/DataBindings/a1a1a1a1-0004-0004-0004-a1a1a1a1a1a1.json"; payload = (ToBase64 $freezerStaticBindingJson); payloadType = "InlineBase64" }
    @{ path = "EntityTypes/1000000000004/DataBindings/a1a1a1a1-0005-0005-0005-a1a1a1a1a1a1.json"; payload = (ToBase64 $freezerTsBindingJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000001/definition.json"; payload = (ToBase64 $soldRelJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000002/definition.json"; payload = (ToBase64 $fromRelJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000003/definition.json"; payload = (ToBase64 $operatesRelJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000001/Contextualizations/b1b1b1b1-0001-0001-0001-b1b1b1b1b1b1.json"; payload = (ToBase64 $soldCtxJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000002/Contextualizations/b1b1b1b1-0002-0002-0002-b1b1b1b1b1b1.json"; payload = (ToBase64 $fromCtxJson); payloadType = "InlineBase64" }
    @{ path = "RelationshipTypes/3000000000003/Contextualizations/b1b1b1b1-0003-0003-0003-b1b1b1b1b1b1.json"; payload = (ToBase64 $operatesCtxJson); payloadType = "InlineBase64" }
)

$headers = Get-FabricHeaders
$updateBody = @{ definition = @{ parts = $ontParts } } | ConvertTo-Json -Depth 10
$updateResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/ontologies/$ontologyId/updateDefinition" `
    -Headers $headers -Body $updateBody
$updateOpId = $updateResponse.Headers["x-ms-operation-id"]
Write-Host "  Updating ontology definition..." -ForegroundColor Yellow
Wait-ForOperation -OperationId $updateOpId

# ─── Phase 6: Data Agent ──────────────────────────────────────────────────────

Write-Host "`n═══ PHASE 6: Create Data Agent ═══" -ForegroundColor Cyan
$headers = Get-FabricHeaders

$daBody = @{ displayName = "RetailOntologyAgent"; type = "DataAgent" } | ConvertTo-Json
$da = Invoke-RestMethod -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items" `
    -Headers $headers -Body $daBody
$dataAgentId = $da.id
Write-Host "  Data Agent: $dataAgentId" -ForegroundColor Green

# Update with AI instructions
$stageConfigJson = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/stageConfiguration/1.0.0/schema.json","aiInstructions":"Support group by in GQL"}'

$daGetResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items/$dataAgentId/getDefinition" `
    -Headers $headers
$daGetOpId = $daGetResponse.Headers["x-ms-operation-id"]
Start-Sleep -Seconds 10
$daGetResult = Invoke-RestMethod -Method GET `
    -Uri "https://api.fabric.microsoft.com/v1/operations/$daGetOpId/result" -Headers $headers
$daPlatformB64 = ($daGetResult.definition.parts | Where-Object { $_.path -eq ".platform" }).payload
$daConfigB64 = ($daGetResult.definition.parts | Where-Object { $_.path -like "*data_agent.json" }).payload

$daParts = @(
    @{ path = ".platform"; payload = $daPlatformB64; payloadType = "InlineBase64" }
    @{ path = "Files/Config/data_agent.json"; payload = $daConfigB64; payloadType = "InlineBase64" }
    @{ path = "Files/Config/draft/stage_config.json"; payload = (ToBase64 $stageConfigJson); payloadType = "InlineBase64" }
)

$headers = Get-FabricHeaders
$daUpdateBody = @{ definition = @{ parts = $daParts } } | ConvertTo-Json -Depth 10
$daUpdateResponse = Invoke-WebRequest -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items/$dataAgentId/updateDefinition" `
    -Headers $headers -Body $daUpdateBody
$daUpdateOpId = $daUpdateResponse.Headers["x-ms-operation-id"]
Wait-ForOperation -OperationId $daUpdateOpId

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       ✅ DEPLOYMENT COMPLETE                             ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Workspace:      $WorkspaceName" -ForegroundColor Green
Write-Host "║  Workspace ID:   $workspaceId" -ForegroundColor Green
Write-Host "║  Lakehouse:      $lakehouseId" -ForegroundColor Green
Write-Host "║  Semantic Model: $semanticModelId" -ForegroundColor Green
Write-Host "║  Eventhouse:     $eventhouseId" -ForegroundColor Green
Write-Host "║  Ontology:       $ontologyId" -ForegroundColor Green
Write-Host "║  Data Agent:     $dataAgentId" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
Write-Host "║  MANUAL STEP: Open Data Agent → Add RetailSalesOntology ║" -ForegroundColor Yellow
Write-Host "║  as a data source in the Fabric portal.                  ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "`n  Portal: https://app.fabric.microsoft.com/groups/$workspaceId" -ForegroundColor Cyan
