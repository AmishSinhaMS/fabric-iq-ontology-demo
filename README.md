# 🧊 Fabric IQ Ontology — End-to-End Automated Solution

> **Lakeshore Retail** — A complete, production-ready implementation of the [Microsoft Fabric Ontology (Preview) Tutorial](https://learn.microsoft.com/en-us/fabric/iq/ontology/tutorial-0-introduction?pivots=semantic-model), fully automated via REST APIs and CLI.

[![Fabric](https://img.shields.io/badge/Microsoft%20Fabric-Ontology%20Preview-blue?logo=microsoft)](https://learn.microsoft.com/en-us/fabric/iq/ontology/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Resources Created](#resources-created)
- [Data Model](#data-model)
- [Ontology Schema](#ontology-schema)
- [Automation Script](#automation-script)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Verification](#verification)
- [Manual Steps](#manual-steps)
- [Sample Queries](#sample-queries)
- [Cleanup](#cleanup)
- [References](#references)

---

## Overview

This repository contains a **fully automated, end-to-end deployment** of the Microsoft Fabric IQ Ontology tutorial for the fictional **Lakeshore Retail** ice cream company. The solution provisions all Fabric resources programmatically using REST APIs — no portal clicks required (except one final Data Agent step).

### What gets deployed

| Layer | Resource | Purpose |
|-------|----------|---------|
| **Storage** | Lakehouse `OntologyDataLH` | Delta tables for stores, products, sales, freezers |
| **Real-Time** | Eventhouse `TelemetryDataEH` | KQL database with freezer telemetry streaming data |
| **Semantic** | Semantic Model `RetailSalesModel` | Direct Lake model with 3 tables and 2 relationships |
| **Knowledge** | Ontology `RetailSalesOntology` | 4 entity types, 5 data bindings, 3 relationship types |
| **AI** | Data Agent `RetailOntologyAgent` | Natural language querying over the ontology graph |

### Key innovation

Unlike the tutorial (which requires 50+ manual UI clicks), this solution uses the **Fabric REST API's ontology definition format** to deploy the entire ontology schema — entity types, properties, data bindings, relationship types, and contextualizations — in a single API call.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    cloud_FabricIQ Demo Workspace                │
│                         (F16 Capacity)                          │
│                                                                 │
│  ┌──────────────┐    ┌───────────────────┐    ┌──────────────┐  │
│  │  Lakehouse   │    │  Semantic Model   │    │  Eventhouse   │  │
│  │ OntologyData │    │ RetailSalesModel  │    │ TelemetryData │  │
│  │     LH       │    │  (Direct Lake)    │    │     EH        │  │
│  │              │    │                   │    │               │  │
│  │ ┌──────────┐ │    │ dimproducts ──┐   │    │ ┌───────────┐ │  │
│  │ │dimstore  │─┼───▶│ dimstore  ───┤   │    │ │ Freezer   │ │  │
│  │ │dimproduct│─┼───▶│ factsales ◀──┘   │    │ │ Telemetry │ │  │
│  │ │factsales │─┼───▶│                   │    │ │  (KQL)    │ │  │
│  │ │freezer   │ │    │ 2 Relationships   │    │ └───────────┘ │  │
│  │ └──────────┘ │    └───────────────────┘    └───────┬───────┘  │
│  └──────┬───────┘                                     │          │
│         │                                             │          │
│         ▼                                             ▼          │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              Ontology: RetailSalesOntology                │    │
│  │                                                           │    │
│  │   ┌─────────┐  sold   ┌──────────┐  from   ┌─────────┐  │    │
│  │   │Products │◀────────│SaleEvent │────────▶│  Store  │  │    │
│  │   └─────────┘         └──────────┘         └────┬────┘  │    │
│  │                                                  │       │    │
│  │                                            operates      │    │
│  │                                                  │       │    │
│  │                                             ┌────▼────┐  │    │
│  │                                             │ Freezer │  │    │
│  │                                             │(+ts data)│  │    │
│  │                                             └─────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│         │                                                        │
│         ▼                                                        │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │           Data Agent: RetailOntologyAgent                 │    │
│  │     "What is the top product by revenue across stores?"   │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Resources Created

### Workspace

| Property | Value |
|----------|-------|
| **Name** | `cloud_FabricIQ Demo` |
| **ID** | `4eda53a5-b067-41e3-b6cd-5630f87b7ac5` |
| **Capacity** | `fabriccloud02` (F16) |
| **Region** | West US 3 |

### Fabric Items

| # | Type | Name | ID | Notes |
|---|------|------|----|-------|
| 1 | Lakehouse | `OntologyDataLH` | `8c09d484-3a0a-4d8c-9238-a9c7feac40fb` | 4 delta tables |
| 2 | SQL Endpoint | `OntologyDataLH` | `87a57b02-b6db-4aab-a7a8-c5ece861741d` | Auto-created |
| 3 | Semantic Model | `RetailSalesModel` | `5ba51688-7a20-47b7-ba69-581774b03e21` | Direct Lake, 3 tables |
| 4 | Eventhouse | `TelemetryDataEH` | `4d39500b-eb66-42bc-85da-eb309f0c4455` | KQL cluster |
| 5 | KQL Database | `TelemetryDataEH` | `54ccef50-7cc9-4f28-a663-3ae74f8ad45a` | 1 table |
| 6 | Ontology | `RetailSalesOntology` | `0b5cb462-ca12-4ff9-a595-143aca0071a5` | 4 entity types |
| 7 | Graph Model | `RetailSalesOntology_graph_*` | `4777f62d-04c6-4b94-aba7-ed51539121c3` | Auto-created |
| 8 | Data Agent | `RetailOntologyAgent` | `488f9ec7-6aad-4e57-8ed4-2813df029fbb` | NL queries |

---

## Data Model

### Lakehouse Tables

#### `dimstore` — 3 rows

| StoreId | StoreName | City | Region | Latitude | Longitude |
|---------|-----------|------|--------|----------|-----------|
| S-PAR-01 | Lakeshore Paris 1 | Paris | France | 48.8566 | 2.3522 |
| S-BER-01 | Lakeshore Berlin 1 | Berlin | Germany | 52.52 | 13.405 |
| S-AMS-01 | Lakeshore Amsterdam 1 | Amsterdam | Netherlands | 52.3676 | 4.9041 |

#### `dimproducts` — 3 rows

| ProductId | ProductName | Category | Subcategory | Brand |
|-----------|-------------|----------|-------------|-------|
| P-ICE-001 | Classic Vanilla Pint | Ice Cream | Pint | Lakeshore Retail |
| P-ICE-002 | Dark Chocolate Pint | Ice Cream | Pint | Lakeshore Retail |
| P-ICE-003 | Strawberry Sorbet Pint | Sorbet | Pint | Lakeshore Retail |

#### `factsales` — 6 rows

| SaleId | SaleDate | StoreId | ProductId | Units | RevenueUSD |
|--------|----------|---------|-----------|-------|------------|
| 1746482 | 2025-08-01 | S-PAR-01 | P-ICE-001 | 34 | 170.0 |
| 8492877 | 2025-08-01 | S-BER-01 | P-ICE-001 | 28 | 140.0 |
| 1746483 | 2025-08-02 | S-PAR-01 | P-ICE-002 | 22 | 132.0 |
| 2637458 | 2025-08-03 | S-AMS-01 | P-ICE-003 | 18 | 108.0 |
| 8492878 | 2025-08-04 | S-BER-01 | P-ICE-002 | 25 | 150.0 |
| 2637459 | 2025-08-05 | S-AMS-01 | P-ICE-001 | 31 | 155.0 |

#### `freezer` — 5 rows

| FreezerId | Model | minSafeTempC | StoreId |
|-----------|-------|--------------|---------|
| F-PAR-01 | ZF-500 | -18.0 | S-PAR-01 |
| F-BER-02 | ZF-600 | -18.0 | S-BER-01 |
| F-AMS-03 | ZF-550 | -18.0 | S-AMS-01 |
| F-PAR-02 | ZF-520 | -18.0 | S-PAR-01 |
| F-BER-03 | ZF-620 | -18.0 | S-BER-01 |

### Eventhouse KQL Table

#### `FreezerTelemetry` — 5 rows (time-series)

| timestamp | storeId | freezerId | temperatureC | humidityPct | doorOpen |
|-----------|---------|-----------|-------------|-------------|----------|
| 2025-08-01T10:00:00Z | S-PAR-01 | F-PAR-01 | -19.2 | 45.0 | 0 |
| 2025-08-01T10:05:00Z | S-PAR-01 | F-PAR-01 | -18.5 | 47.2 | 1 |
| 2025-08-01T10:10:00Z | S-PAR-01 | F-PAR-01 | -17.8 | 49.1 | 0 |
| 2025-08-02T09:55:00Z | S-BER-01 | F-BER-02 | -20.1 | 41.0 | 0 |
| 2025-08-03T11:20:00Z | S-AMS-01 | F-AMS-03 | -16.9 | 52.3 | 1 |

### Semantic Model Relationships

```
factsales.StoreId   ──── *:1 ────▶  dimstore.StoreId
factsales.ProductId ──── *:1 ────▶  dimproducts.ProductId
```

**Verified via DAX:**

| Store | Product | Revenue | Units |
|-------|---------|---------|-------|
| Lakeshore Paris 1 | Classic Vanilla Pint | $170 | 34 |
| Lakeshore Berlin 1 | Classic Vanilla Pint | $140 | 28 |
| Lakeshore Paris 1 | Dark Chocolate Pint | $132 | 22 |
| Lakeshore Amsterdam 1 | Strawberry Sorbet Pint | $108 | 18 |
| Lakeshore Berlin 1 | Dark Chocolate Pint | $150 | 25 |
| Lakeshore Amsterdam 1 | Classic Vanilla Pint | $155 | 31 |

---

## Ontology Schema

### Entity Types

| Entity Type | Key | Static Properties | Time-Series Properties | Data Source |
|-------------|-----|-------------------|----------------------|-------------|
| **Store** | `StoreId` | StoreId, StoreName, City, Region, Latitude, Longitude | — | `dimstore` (Lakehouse) |
| **Products** | `ProductId` | ProductId, ProductName, Category, Subcategory, Brand | — | `dimproducts` (Lakehouse) |
| **SaleEvent** | `SaleId` | SaleId, SaleDate, SaleStoreId, SaleProductId, Units, RevenueUSD | — | `factsales` (Lakehouse) |
| **Freezer** | `FreezerId` | FreezerId, FreezerModel, minSafeTempC, FreezerStoreId | tsTimestamp, temperatureC, humidityPct, doorOpen | `freezer` (Lakehouse) + `FreezerTelemetry` (Eventhouse) |

### Relationship Types

| Relationship | Source Entity | Target Entity | Contextualization Table | Source Key Column | Target Key Column |
|-------------|--------------|---------------|------------------------|-------------------|-------------------|
| **sold** | SaleEvent | Products | `factsales` | SaleId | ProductId |
| **from_store** | SaleEvent | Store | `factsales` | SaleId | StoreId |
| **operates** | Store | Freezer | `freezer` | StoreId | FreezerId |

### Ontology Graph Visualization

```
                    ┌─────────────────┐
                    │    Products     │
                    │ ─────────────── │
                    │ ProductId (key) │
                    │ ProductName     │
                    │ Category        │
                    │ Subcategory     │
                    │ Brand           │
                    └────────▲────────┘
                             │
                          sold │
                             │
┌─────────────────┐  from   ┌─────────────────┐
│      Store      │◀────────│    SaleEvent     │
│ ─────────────── │  _store │ ─────────────── │
│ StoreId (key)   │         │ SaleId (key)    │
│ StoreName       │         │ SaleDate        │
│ City            │         │ SaleStoreId     │
│ Region          │         │ SaleProductId   │
│ Latitude        │         │ Units           │
│ Longitude       │         │ RevenueUSD      │
└────────┬────────┘         └─────────────────┘
         │
    operates
         │
         ▼
┌─────────────────────────────┐
│          Freezer            │
│ ─────────────────────────── │
│ FreezerId (key)             │
│ FreezerModel                │
│ minSafeTempC                │
│ FreezerStoreId              │
│ ─── Time Series ─────────── │
│ 📊 temperatureC             │
│ 📊 humidityPct              │
│ 📊 doorOpen                 │
│ 🕐 tsTimestamp              │
└─────────────────────────────┘
```

---

## Automation Script

The automation is broken into clear phases. See [`scripts/deploy.ps1`](scripts/deploy.ps1) for the full script.

### Phase 1 — Workspace & Capacity
```powershell
# Create workspace and assign to Fabric capacity
POST /v1/workspaces
POST /v1/workspaces/{id}/assignToCapacity
```

### Phase 2 — Lakehouse & Data
```powershell
# Create lakehouse, upload CSVs via OneLake DFS, load to delta tables
POST /v1/workspaces/{id}/items          # type: Lakehouse
PUT  onelake.dfs.fabric.microsoft.com   # Upload files
POST /v1/workspaces/{id}/lakehouses/{id}/tables/{name}/load
```

### Phase 3 — Semantic Model
```powershell
# Create Direct Lake semantic model with BIM definition
POST /v1/workspaces/{id}/items  # type: SemanticModel
# Includes: definition.pbism + model.bim with tables, columns, relationships
```

### Phase 4 — Eventhouse & KQL
```powershell
# Create eventhouse, then create table and ingest data via Kusto REST API
POST /v1/workspaces/{id}/items              # type: Eventhouse
POST {kustoUri}/v1/rest/mgmt               # .create table
POST {kustoUri}/v1/rest/mgmt               # .ingest inline
```

### Phase 5 — Ontology (Key Innovation)
```powershell
# Create empty ontology, then update definition with full schema
POST /v1/workspaces/{id}/items              # type: Ontology
POST /v1/workspaces/{id}/ontologies/{id}/getDefinition   # Get format
POST /v1/workspaces/{id}/ontologies/{id}/updateDefinition
# Includes: 4 EntityTypes + 5 DataBindings + 3 RelationshipTypes + 3 Contextualizations
```

### Phase 6 — Data Agent
```powershell
# Create data agent and configure instructions
POST /v1/workspaces/{id}/items              # type: DataAgent
POST /v1/workspaces/{id}/items/{id}/updateDefinition
# Includes: AI instructions "Support group by in GQL"
```

---

## Prerequisites

- **Azure subscription** with Microsoft Fabric enabled
- **Fabric capacity** (F2 or higher, or Trial)
- **Azure CLI** installed and authenticated (`az login`)
- **Tenant settings** enabled:
  - _Enable Ontology item (preview)_
  - _User can create Graph (preview)_
  - _Users can create and share Data agent item types (preview)_
  - _Users can use Copilot and other features powered by Azure OpenAI_

---

## Quick Start

### Option 1: Run the automation script

```powershell
# 1. Clone this repo
git clone https://github.com/<your-org>/fabric-iq-ontology-demo.git
cd fabric-iq-ontology-demo

# 2. Login to Azure
az login

# 3. Run the deployment (edit variables at top of script)
.\scripts\deploy.ps1
```

### Option 2: Follow the step-by-step guide

See [`docs/step-by-step.md`](docs/step-by-step.md) for a detailed walkthrough of each API call.

---

## Verification

### DAX Query (Semantic Model)

```dax
EVALUATE
SUMMARIZECOLUMNS(
    dimstore[StoreName],
    dimproducts[ProductName],
    "TotalRevenue", SUM(factsales[RevenueUSD]),
    "TotalUnits", SUM(factsales[Units])
)
```

### KQL Query (Eventhouse)

```kql
FreezerTelemetry
| summarize avg(temperatureC), avg(humidityPct) by freezerId
```

### Ontology Graph Query (Data Agent)

> *"What is the top product by revenue across all stores?"*
>
> *"For each store, show any freezers operated by that store that ever had a humidity lower than 46 percent."*

---

## Manual Steps

Only **one manual step** is required after the automated deployment:

1. Open the **`RetailOntologyAgent`** Data Agent in the [Fabric portal](https://app.fabric.microsoft.com)
2. Click **Add a data source**
3. Search for `RetailSalesOntology` → Click **Add**

> **Why?** The Data Agent definition API (schema v2.1.0) does not yet support persisting `dataSources` through the `updateDefinition` endpoint. This is expected to be resolved when the API reaches GA.

---

## Sample Queries

### Natural Language (via Data Agent)

| Question | Expected Behavior |
|----------|-------------------|
| "What is the top product by revenue across all stores?" | Returns Classic Vanilla Pint ($465) |
| "Which store has the most sales?" | Compares across Paris, Berlin, Amsterdam |
| "Show all freezers operated in the Paris store" | Returns F-PAR-01 and F-PAR-02 |
| "Which freezers had temperature above -18°C?" | Finds F-PAR-01 (-17.8°C) and F-AMS-03 (-16.9°C) |

### Graph Query Builder (via Ontology Preview)

1. Filter: `Store.StoreId = S-PAR-01`
2. Components: Store + Freezer + operates
3. **Result**: 2 freezers (F-PAR-01, F-PAR-02) connected to Paris store

---

## Cleanup

To delete all resources:

```powershell
$workspaceId = "4eda53a5-b067-41e3-b6cd-5630f87b7ac5"
$token = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

# Delete the entire workspace (removes everything inside)
Invoke-RestMethod -Method DELETE `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId" `
    -Headers $headers
```

---

## References

- [Ontology Tutorial (Microsoft Learn)](https://learn.microsoft.com/en-us/fabric/iq/ontology/tutorial-0-introduction?pivots=semantic-model)
- [Ontology REST API — Create](https://learn.microsoft.com/en-us/rest/api/fabric/ontology/items/create-ontology)
- [Ontology Definition Format](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/ontology-definition)
- [Fabric REST API Overview](https://learn.microsoft.com/en-us/rest/api/fabric/core/items)
- [Sample Data (GitHub)](https://github.com/microsoft/fabric-samples/tree/main/docs-samples/iq/ontology)

---

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

---

*Built with ❄️ by GitHub Copilot CLI — fully automated Fabric deployment*
