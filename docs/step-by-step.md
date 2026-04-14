# Step-by-Step API Walkthrough

This document provides a detailed explanation of each API call made during the automated deployment.

## Authentication

All Fabric REST API calls require a Bearer token. Different APIs require different resource scopes:

| API | Token Resource | Usage |
|-----|---------------|-------|
| Fabric REST API | `https://api.fabric.microsoft.com` | Workspace, items, ontology |
| OneLake DFS | `https://storage.azure.com` | File upload to lakehouse |
| Kusto/KQL | `https://kusto.kusto.windows.net` | Eventhouse management/queries |
| Power BI | `https://analysis.windows.net/powerbi/api` | DAX query execution |

```powershell
# Example: Get a Fabric API token
$token = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
```

---

## Phase 1: Workspace Creation

### Create Workspace

```http
POST https://api.fabric.microsoft.com/v1/workspaces
Content-Type: application/json

{ "displayName": "cloud_FabricIQ Demo" }
```

**Response**: `201 Created` with workspace ID.

### Assign Capacity

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/assignToCapacity
Content-Type: application/json

{ "capacityId": "{fabricCapacityId}" }
```

---

## Phase 2: Lakehouse & Data Loading

### Create Lakehouse

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
Content-Type: application/json

{ "displayName": "OntologyDataLH", "type": "Lakehouse" }
```

### Upload Files via OneLake DFS

Three-step process per file:

```http
# 1. Create file resource
PUT https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/{fileName}?resource=file

# 2. Append content
PATCH https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/{fileName}?position=0&action=append
Content-Type: application/octet-stream
[file bytes]

# 3. Flush to finalize
PATCH https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/{fileName}?position={fileSize}&action=flush
```

### Load CSV to Delta Table

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/lakehouses/{lakehouseId}/tables/{tableName}/load
Content-Type: application/json

{
  "relativePath": "Files/DimStore.csv",
  "pathType": "File",
  "mode": "Overwrite",
  "formatOptions": { "format": "Csv", "header": true, "delimiter": "," }
}
```

**Response**: `202 Accepted` — long-running operation.

---

## Phase 3: Semantic Model (Direct Lake)

### Create with BIM Definition

The semantic model requires two definition files:
- `definition.pbism` — minimal connection metadata: `{"version":"1.0"}`
- `model.bim` — full Tabular Model definition (JSON) with:
  - Tables with columns and Direct Lake partitions
  - Relationships (Many-to-One)
  - M expression pointing to the SQL Analytics Endpoint

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
Content-Type: application/json

{
  "displayName": "RetailSalesModel",
  "type": "SemanticModel",
  "definition": {
    "parts": [
      { "path": "definition.pbism", "payload": "{base64}", "payloadType": "InlineBase64" },
      { "path": "model.bim", "payload": "{base64}", "payloadType": "InlineBase64" }
    ]
  }
}
```

**Key insight**: The `model.bim` M expression must reference the SQL Analytics Endpoint server and the SQL Endpoint ID (not the lakehouse ID).

---

## Phase 4: Eventhouse & KQL

### Create Eventhouse

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
{ "displayName": "TelemetryDataEH", "type": "Eventhouse" }
```

A default KQL Database is auto-created.

### Create Table (Kusto REST API)

```http
POST {kustoUri}/v1/rest/mgmt

{
  "db": "TelemetryDataEH",
  "csl": ".create table FreezerTelemetry (timestamp: datetime, storeId: string, freezerId: string, temperatureC: real, humidityPct: real, doorOpen: int)"
}
```

### Ingest Data Inline

```http
POST {kustoUri}/v1/rest/mgmt

{
  "db": "TelemetryDataEH",
  "csl": ".ingest inline into table FreezerTelemetry <|\n2025-08-01T10:00:00Z,S-PAR-01,F-PAR-01,-19.2,45.0,0\n..."
}
```

---

## Phase 5: Ontology (Key Innovation)

### Two-Step Process

1. **Create empty ontology** — standard item creation
2. **Update with full definition** — uses the ontology definition API

### Step 1: Create Empty

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
{ "displayName": "RetailSalesOntology", "type": "Ontology" }
```

### Step 2: Get Platform Definition

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/ontologies/{ontologyId}/getDefinition
```

This returns the `.platform` file with the correct schema reference, which must be included in the update.

### Step 3: Update with Full Definition

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/ontologies/{ontologyId}/updateDefinition

{
  "definition": {
    "parts": [
      { "path": ".platform", "payload": "..." },
      { "path": "definition.json", "payload": "e30=" },
      { "path": "EntityTypes/{id}/definition.json", "payload": "..." },
      { "path": "EntityTypes/{id}/DataBindings/{guid}.json", "payload": "..." },
      { "path": "RelationshipTypes/{id}/definition.json", "payload": "..." },
      { "path": "RelationshipTypes/{id}/Contextualizations/{guid}.json", "payload": "..." }
    ]
  }
}
```

### Ontology Definition Schema

See the [official documentation](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/ontology-definition) for the complete schema reference.

**Important notes:**
- Entity type IDs must be unique positive 64-bit integers
- Property names should be unique across ALL entity types
- Data bindings map source columns to property IDs
- Contextualizations bind relationships to data tables via key column mappings

---

## Phase 6: Data Agent

### Create Agent

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
{ "displayName": "RetailOntologyAgent", "type": "DataAgent" }
```

### Update Instructions

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{dataAgentId}/updateDefinition

{
  "definition": {
    "parts": [
      { "path": "Files/Config/draft/stage_config.json", "payload": "{base64 of instructions JSON}" }
    ]
  }
}
```

The `stage_config.json` sets `aiInstructions` to `"Support group by in GQL"`.

### Manual Step

The Data Agent's data source (ontology) must be added via the Fabric portal UI:
1. Open RetailOntologyAgent
2. Click **Add a data source**
3. Select RetailSalesOntology → **Add**
