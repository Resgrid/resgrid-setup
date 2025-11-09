# AMBIPAR RESPONSE CANADA - RESGRID IMPLEMENTATION PLAN

**Project:** Custom Resgrid Deployment for Ambipar Response Canada Inc.
**Version:** 1.0
**Date:** November 2025
**Status:** Planning Phase

---

## EXECUTIVE SUMMARY

This document outlines the comprehensive implementation plan for customizing the Resgrid open-source emergency response platform for Ambipar Response Canada Inc., an industrial emergency response company operating across Canada.

**Key Deliverables:**
1. Seven Operational Categories System
2. AI-Powered Operations Module
3. External System Integrations (SharePoint, Power Apps, Geotab, Replicon, Microsoft 365)
4. Canadian Multi-Jurisdictional Compliance Framework
5. Offline-First Remote Operations Support
6. Enhanced Reporting & Analytics
7. Industrial Client Management System

**Timeline:** 16-20 weeks (4-5 months)
**Architecture:** Microservices with Docker Compose deployment
**Tech Stack:** ASP.NET Core, PostgreSQL, Redis, RabbitMQ, AI (OpenAI/Azure/Anthropic)

---

## TABLE OF CONTENTS

1. [Project Architecture](#project-architecture)
2. [Implementation Phases](#implementation-phases)
3. [Phase 1: Foundation & Infrastructure](#phase-1-foundation--infrastructure)
4. [Phase 2: Seven Operational Categories](#phase-2-seven-operational-categories)
5. [Phase 3: AI Service Layer](#phase-3-ai-service-layer)
6. [Phase 4: External Integrations](#phase-4-external-integrations)
7. [Phase 5: Compliance & Certification](#phase-5-compliance--certification)
8. [Phase 6: Reporting & Analytics](#phase-6-reporting--analytics)
9. [Phase 7: Testing & Deployment](#phase-7-testing--deployment)
10. [Database Schema Design](#database-schema-design)
11. [API Endpoints](#api-endpoints)
12. [Configuration Management](#configuration-management)
13. [Security & Compliance](#security--compliance)
14. [Performance Requirements](#performance-requirements)
15. [Deployment Strategy](#deployment-strategy)

---

## PROJECT ARCHITECTURE

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Caddy Reverse Proxy (SSL)                   │
│                     https://resgrid.ambipar.ca                  │
└───────────┬──────────────┬──────────────┬─────────────┬────────┘
            │              │              │             │
    ┌───────▼───────┐ ┌───▼────────┐ ┌──▼──────┐ ┌───▼─────────┐
    │  Web App UI   │ │  REST API  │ │ SignalR │ │ AI Service  │
    │   (Web)       │ │   (API)    │ │ Events  │ │  (NEW)      │
    └───────┬───────┘ └───┬────────┘ └──┬──────┘ └───┬─────────┘
            │              │              │             │
            └──────────────┴──────────────┴─────────────┘
                                  │
        ┌─────────────────────────┼────────────────────────┐
        │                         │                        │
  ┌─────▼─────┐         ┌────────▼─────────┐      ┌──────▼──────┐
  │ PostgreSQL│         │     Redis        │      │  RabbitMQ   │
  │ (Primary) │         │   (Cache)        │      │  (Queue)    │
  └─────┬─────┘         └────────┬─────────┘      └──────┬──────┘
        │                        │                        │
        │                        └────────────────────────┘
        │                                  │
  ┌─────▼──────────────────────────────────▼───────────────────┐
  │              Background Workers                            │
  │  • Dispatch Worker    • Compliance Worker                  │
  │  • AI Worker          • Integration Worker                 │
  │  • Notification Worker • Sync Worker (Offline)             │
  └────────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┴─────────────────┐
        │                                   │
  ┌─────▼────────┐                  ┌──────▼──────────┐
  │  External    │                  │  Mobile Apps    │
  │  Systems:    │                  │  (iOS/Android)  │
  │  • SharePoint│                  │  • Offline Mode │
  │  • Power Apps│                  │  • GPS Tracking │
  │  • Geotab    │                  │  • Push Notify  │
  │  • Replicon  │                  └─────────────────┘
  │  • M365      │
  └──────────────┘
```

### Microservices Architecture

**Service Breakdown:**

| Service | Image | Purpose | Port | Dependencies |
|---------|-------|---------|------|--------------|
| **resgrid-web** | resgridllc/resgridwebcore:ambipar | Main web application UI | 5151 | api, events, db, redis |
| **resgrid-api** | resgridllc/resgridwebservices:ambipar | REST API v4 | 5152 | db, redis, rabbitmq, ai |
| **resgrid-events** | resgridllc/resgridwebevents:ambipar | SignalR real-time hub | 5153 | db, redis, rabbitmq |
| **resgrid-ai** | resgridllc/resgridai:ambipar | AI processing service (NEW) | 5154 | db, redis, rabbitmq |
| **resgrid-worker** | resgridllc/resgridworkersconsole:ambipar | Background workers | - | db, redis, rabbitmq |
| **resgrid-integrations** | resgridllc/resgridintegrations:ambipar | External integrations (NEW) | 5155 | db, redis, api |
| **postgresql** | postgres:16 | Primary database | 5432 | - |
| **redis** | redis:alpine | Caching & sessions | 6379 | - |
| **rabbitmq** | rabbitmq:3-management | Message queue | 5672, 15672 | - |
| **caddy** | caddy:2 | Reverse proxy & SSL | 80, 443 | - |

---

## IMPLEMENTATION PHASES

### Phase Overview

| Phase | Duration | Deliverables | Risk Level |
|-------|----------|--------------|------------|
| **Phase 1: Foundation** | 2 weeks | Infrastructure, DB migrations, config | Low |
| **Phase 2: Categories** | 2 weeks | Seven operational categories system | Low |
| **Phase 3: AI Layer** | 4 weeks | AI service implementation | Medium |
| **Phase 4: Integrations** | 3 weeks | External system connectors | High |
| **Phase 5: Compliance** | 2 weeks | Certification & regulatory tracking | Medium |
| **Phase 6: Reporting** | 2 weeks | Enhanced analytics & reports | Low |
| **Phase 7: Testing** | 3 weeks | QA, UAT, deployment | Medium |

**Total Duration:** 18 weeks (4.5 months)

---

## PHASE 1: FOUNDATION & INFRASTRUCTURE

**Duration:** 2 weeks
**Dependencies:** None
**Risk:** Low

### 1.1 Repository Setup

**Tasks:**
- [ ] Fork Resgrid Core repository to Ambipar GitHub organization
- [ ] Create `ambipar-main` branch as primary development branch
- [ ] Set up branch protection rules
- [ ] Configure CI/CD pipelines (GitHub Actions)
- [ ] Create development, staging, production environments

**Repository Structure:**
```
resgrid-ambipar/
├── Core/
│   ├── Resgrid.Model/
│   ├── Resgrid.Services/
│   ├── Resgrid.Config/
│   └── Resgrid.Model.Ambipar/ (NEW)
│       ├── Entities/
│       │   ├── OperationalCategory.cs
│       │   ├── ComplianceRequirement.cs
│       │   ├── ComplianceRecord.cs
│       │   ├── AIAnalysisResult.cs
│       │   └── ExternalSystemLog.cs
│       ├── Services/
│       │   ├── IAIService.cs
│       │   ├── IComplianceService.cs
│       │   ├── IIntegrationService.cs
│       │   └── IOperationalCategoryService.cs
│       └── ViewModels/
├── Providers/
│   ├── Resgrid.Providers.AI/ (NEW)
│   ├── Resgrid.Providers.Ambipar.Integrations/ (NEW)
│   └── Resgrid.Providers.Ambipar.Compliance/ (NEW)
├── Web/
│   └── Resgrid.Web.Services.Ambipar/ (NEW - Custom API controllers)
├── Workers/
│   └── Resgrid.Workers.Ambipar/ (NEW - Custom workers)
└── Docker/
    ├── docker-compose.ambipar.yml
    └── Dockerfiles/
```

### 1.2 Database Schema Design

**New Tables Required:**

**1. Operational Categories Tables:**
```sql
CREATE TABLE AmbiparOperationalCategories (
    OperationalCategoryId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    CategoryCode VARCHAR(20) NOT NULL, -- FIRE, MEDICAL, HAZMAT, RESCUE, SAFETY, SUPPORT, TRAINING
    CategoryName VARCHAR(100) NOT NULL,
    CategoryDescription TEXT,
    CategoryColor VARCHAR(7), -- Hex color
    DisplayOrder INTEGER NOT NULL,
    IsActive BOOLEAN DEFAULT TRUE,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    CreatedByUserId UUID NOT NULL,
    UpdatedOn TIMESTAMP,
    UpdatedByUserId UUID
);

CREATE TABLE AmbiparCategoryAssignments (
    CategoryAssignmentId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    OperationalCategoryId UUID NOT NULL REFERENCES AmbiparOperationalCategories(OperationalCategoryId),
    EntityType VARCHAR(50) NOT NULL, -- 'Unit', 'Personnel', 'Inventory', 'Call', 'Protocol'
    EntityId INTEGER NOT NULL,
    IsPrimary BOOLEAN DEFAULT FALSE,
    Notes TEXT,
    AssignedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    AssignedByUserId UUID NOT NULL
);

CREATE INDEX idx_category_assignments_entity ON AmbiparCategoryAssignments(EntityType, EntityId);
CREATE INDEX idx_category_assignments_category ON AmbiparCategoryAssignments(OperationalCategoryId);
```

**2. AI Analysis Tables:**
```sql
CREATE TABLE AmbiparAIAnalysisResults (
    AIAnalysisResultId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    AnalysisType VARCHAR(50) NOT NULL, -- 'Dispatch', 'Hazmat', 'Equipment', 'Incident', 'Query', 'Compliance', 'Safety'
    EntityType VARCHAR(50), -- 'Call', 'Unit', 'Personnel', etc.
    EntityId INTEGER,
    RequestPayload JSONB, -- Store the input data
    ResponsePayload JSONB, -- Store AI response
    ProviderType VARCHAR(50), -- 'OpenAI', 'Azure', 'Anthropic'
    ModelUsed VARCHAR(100), -- 'gpt-4', 'claude-3-opus', etc.
    TokensUsed INTEGER,
    ProcessingTimeMs INTEGER,
    Confidence DECIMAL(5,2), -- 0.00 to 100.00
    IsSuccessful BOOLEAN DEFAULT TRUE,
    ErrorMessage TEXT,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    CreatedByUserId UUID
);

CREATE INDEX idx_ai_analysis_entity ON AmbiparAIAnalysisResults(EntityType, EntityId);
CREATE INDEX idx_ai_analysis_type ON AmbiparAIAnalysisResults(AnalysisType, CreatedOn DESC);
```

**3. Compliance & Certification Tables:**
```sql
CREATE TABLE AmbiparComplianceRequirements (
    ComplianceRequirementId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    RequirementCode VARCHAR(50) NOT NULL, -- 'OFA3', 'TDG', 'CONFINED_SPACE', etc.
    RequirementName VARCHAR(200) NOT NULL,
    RequirementType VARCHAR(50) NOT NULL, -- 'Certification', 'Equipment', 'Training', 'Regulatory'
    IssuingAuthority VARCHAR(200), -- 'WorkSafeBC', 'Transport Canada', 'NFPA', etc.
    RegulatoryReference TEXT, -- Reference to specific regulation
    Description TEXT,
    ValidityPeriodDays INTEGER, -- NULL for no expiry
    WarningPeriodDays INTEGER, -- Days before expiry to warn
    IsMandatory BOOLEAN DEFAULT TRUE,
    AppliesTo VARCHAR(50), -- 'Personnel', 'Unit', 'Station', 'Department'
    OperationalCategoryId UUID REFERENCES AmbiparOperationalCategories(OperationalCategoryId),
    IsActive BOOLEAN DEFAULT TRUE,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    CreatedByUserId UUID NOT NULL
);

CREATE TABLE AmbiparComplianceRecords (
    ComplianceRecordId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ComplianceRequirementId UUID NOT NULL REFERENCES AmbiparComplianceRequirements(ComplianceRequirementId),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    EntityType VARCHAR(50) NOT NULL, -- 'Personnel', 'Unit', 'Equipment'
    EntityId INTEGER NOT NULL,
    CertificationNumber VARCHAR(100),
    IssuedDate DATE,
    ExpiryDate DATE,
    Status VARCHAR(50) NOT NULL, -- 'Current', 'Expiring', 'Expired', 'Pending', 'Suspended'
    DocumentUrl TEXT, -- Link to certificate/document
    DocumentSharePointId VARCHAR(200), -- SharePoint document ID
    VerifiedBy VARCHAR(200),
    VerifiedDate TIMESTAMP,
    Notes TEXT,
    LastCheckedOn TIMESTAMP,
    NextCheckDate DATE,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    CreatedByUserId UUID NOT NULL,
    UpdatedOn TIMESTAMP,
    UpdatedByUserId UUID
);

CREATE INDEX idx_compliance_records_entity ON AmbiparComplianceRecords(EntityType, EntityId);
CREATE INDEX idx_compliance_records_expiry ON AmbiparComplianceRecords(ExpiryDate);
CREATE INDEX idx_compliance_records_status ON AmbiparComplianceRecords(Status);
```

**4. External Integration Tables:**
```sql
CREATE TABLE AmbiparExternalSystemLogs (
    ExternalSystemLogId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    SystemType VARCHAR(50) NOT NULL, -- 'SharePoint', 'PowerApps', 'Geotab', 'Replicon', 'M365'
    OperationType VARCHAR(50) NOT NULL, -- 'Sync', 'Create', 'Update', 'Delete', 'Query'
    EntityType VARCHAR(50),
    EntityId INTEGER,
    ExternalEntityId VARCHAR(200), -- ID in external system
    RequestPayload TEXT,
    ResponsePayload TEXT,
    IsSuccessful BOOLEAN DEFAULT TRUE,
    ErrorMessage TEXT,
    ProcessingTimeMs INTEGER,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE AmbiparGeotabVehicleTracking (
    GeotabVehicleTrackingId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    UnitId INTEGER NOT NULL REFERENCES Units(UnitId),
    GeotabDeviceId VARCHAR(100) NOT NULL,
    Latitude DECIMAL(10,7),
    Longitude DECIMAL(10,7),
    Speed DECIMAL(5,2), -- km/h
    Heading INTEGER, -- 0-359 degrees
    Odometer INTEGER, -- kilometers
    EngineHours DECIMAL(10,2),
    FuelLevel DECIMAL(5,2), -- percentage
    TrackedOn TIMESTAMP NOT NULL,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_geotab_unit ON AmbiparGeotabVehicleTracking(UnitId, TrackedOn DESC);
CREATE INDEX idx_geotab_device ON AmbiparGeotabVehicleTracking(GeotabDeviceId);

CREATE TABLE AmbiparRepliconTimeEntries (
    RepliconTimeEntryId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    UserId UUID NOT NULL REFERENCES AspNetUsers(Id),
    CallId INTEGER REFERENCES Calls(CallId),
    RepliconExternalId VARCHAR(200), -- ID in Replicon
    ProjectCode VARCHAR(100),
    ClientName VARCHAR(200),
    StartTime TIMESTAMP NOT NULL,
    EndTime TIMESTAMP NOT NULL,
    TotalHours DECIMAL(5,2),
    IsBillable BOOLEAN DEFAULT TRUE,
    HourlyRate DECIMAL(10,2),
    Status VARCHAR(50), -- 'Draft', 'Submitted', 'Approved', 'Synced'
    SyncedToReplicon BOOLEAN DEFAULT FALSE,
    SyncedOn TIMESTAMP,
    Notes TEXT,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW()
);
```

**5. Industrial Client Management Tables:**
```sql
CREATE TABLE AmbiparClients (
    ClientId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    DepartmentId INTEGER NOT NULL REFERENCES Departments(DepartmentId),
    ClientCode VARCHAR(50) NOT NULL UNIQUE,
    ClientName VARCHAR(200) NOT NULL,
    Industry VARCHAR(100), -- 'Oil & Gas', 'Mining', 'Data Center', 'Manufacturing', etc.
    Address TEXT,
    City VARCHAR(100),
    Province VARCHAR(50),
    PostalCode VARCHAR(10),
    Country VARCHAR(50) DEFAULT 'Canada',
    PrimaryContactName VARCHAR(200),
    PrimaryContactEmail VARCHAR(200),
    PrimaryContactPhone VARCHAR(50),
    ContractNumber VARCHAR(100),
    ContractStartDate DATE,
    ContractEndDate DATE,
    SLAResponseTimeMinutes INTEGER,
    BillingType VARCHAR(50), -- 'Hourly', 'Monthly', 'Per Incident', 'Contract'
    BillingRate DECIMAL(10,2),
    IsActive BOOLEAN DEFAULT TRUE,
    Notes TEXT,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW(),
    CreatedByUserId UUID NOT NULL,
    UpdatedOn TIMESTAMP,
    UpdatedByUserId UUID
);

CREATE TABLE AmbiparClientSites (
    ClientSiteId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ClientId UUID NOT NULL REFERENCES AmbiparClients(ClientId),
    SiteName VARCHAR(200) NOT NULL,
    SiteCode VARCHAR(50),
    Address TEXT NOT NULL,
    City VARCHAR(100),
    Province VARCHAR(50),
    PostalCode VARCHAR(10),
    Latitude DECIMAL(10,7),
    Longitude DECIMAL(10,7),
    SiteContactName VARCHAR(200),
    SiteContactPhone VARCHAR(50),
    AccessRequirements TEXT,
    HazardsPresent TEXT,
    SpecialProtocols TEXT,
    IsActive BOOLEAN DEFAULT TRUE,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE AmbiparClientDeployments (
    ClientDeploymentId UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    CallId INTEGER NOT NULL REFERENCES Calls(CallId),
    ClientId UUID NOT NULL REFERENCES AmbiparClients(ClientId),
    ClientSiteId UUID REFERENCES AmbiparClientSites(ClientSiteId),
    ProjectCode VARCHAR(100),
    PurchaseOrderNumber VARCHAR(100),
    BillableHours DECIMAL(10,2),
    BillableAmount DECIMAL(10,2),
    InvoiceNumber VARCHAR(100),
    InvoiceDate DATE,
    InvoiceStatus VARCHAR(50), -- 'Draft', 'Sent', 'Paid', 'Overdue'
    Notes TEXT,
    CreatedOn TIMESTAMP NOT NULL DEFAULT NOW()
);
```

### 1.3 Migration Scripts

**Location:** `/Providers/Resgrid.Providers.MigrationsPg/Migrations/`

**Files to Create:**
```
M0037_AmbiparOperationalCategories.cs
M0038_AmbiparAIAnalysis.cs
M0039_AmbiparCompliance.cs
M0040_AmbiparExternalIntegrations.cs
M0041_AmbiparClientManagement.cs
```

**Migration Example (M0037):**
```csharp
using FluentMigrator;

namespace Resgrid.Providers.MigrationsPg.Migrations
{
    [Migration(37)]
    public class M0037_AmbiparOperationalCategories : Migration
    {
        public override void Up()
        {
            Create.Table("AmbiparOperationalCategories")
                .WithColumn("OperationalCategoryId").AsGuid().PrimaryKey()
                .WithColumn("DepartmentId").AsInt32().NotNullable()
                    .ForeignKey("FK_AmbiparOperationalCategories_Departments", "Departments", "DepartmentId")
                .WithColumn("CategoryCode").AsString(20).NotNullable()
                .WithColumn("CategoryName").AsString(100).NotNullable()
                .WithColumn("CategoryDescription").AsString().Nullable()
                .WithColumn("CategoryColor").AsString(7).Nullable()
                .WithColumn("DisplayOrder").AsInt32().NotNullable()
                .WithColumn("IsActive").AsBoolean().NotNullable().WithDefaultValue(true)
                .WithColumn("CreatedOn").AsDateTime().NotNullable().WithDefault(SystemMethods.CurrentDateTime)
                .WithColumn("CreatedByUserId").AsGuid().NotNullable()
                .WithColumn("UpdatedOn").AsDateTime().Nullable()
                .WithColumn("UpdatedByUserId").AsGuid().Nullable();

            Create.Table("AmbiparCategoryAssignments")
                .WithColumn("CategoryAssignmentId").AsGuid().PrimaryKey()
                .WithColumn("OperationalCategoryId").AsGuid().NotNullable()
                    .ForeignKey("FK_AmbiparCategoryAssignments_Categories", "AmbiparOperationalCategories", "OperationalCategoryId")
                .WithColumn("EntityType").AsString(50).NotNullable()
                .WithColumn("EntityId").AsInt32().NotNullable()
                .WithColumn("IsPrimary").AsBoolean().NotNullable().WithDefaultValue(false)
                .WithColumn("Notes").AsString().Nullable()
                .WithColumn("AssignedOn").AsDateTime().NotNullable().WithDefault(SystemMethods.CurrentDateTime)
                .WithColumn("AssignedByUserId").AsGuid().NotNullable();

            Create.Index("idx_category_assignments_entity")
                .OnTable("AmbiparCategoryAssignments")
                .OnColumn("EntityType").Ascending()
                .OnColumn("EntityId").Ascending();

            Create.Index("idx_category_assignments_category")
                .OnTable("AmbiparCategoryAssignments")
                .OnColumn("OperationalCategoryId").Ascending();

            // Insert default Ambipar operational categories
            Insert.IntoTable("AmbiparOperationalCategories")
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1, // Update with actual Ambipar department ID
                    CategoryCode = "FIRE",
                    CategoryName = "Fire Suppression",
                    CategoryDescription = "Fire suppression, foam systems, wildfire operations",
                    CategoryColor = "#FF0000",
                    DisplayOrder = 1,
                    CreatedByUserId = System.Guid.Empty // System user
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "MEDICAL",
                    CategoryName = "Medical Services",
                    CategoryDescription = "EMS operations, OFA3, trauma response, patient transport",
                    CategoryColor = "#00FF00",
                    DisplayOrder = 2,
                    CreatedByUserId = System.Guid.Empty
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "HAZMAT",
                    CategoryName = "Hazardous Materials",
                    CategoryDescription = "Dangerous goods, chemical spills, decontamination, TDG compliance",
                    CategoryColor = "#FF9900",
                    DisplayOrder = 3,
                    CreatedByUserId = System.Guid.Empty
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "RESCUE",
                    CategoryName = "Technical Rescue",
                    CategoryDescription = "Rope, confined space, vehicle extrication, swiftwater rescue",
                    CategoryColor = "#0099FF",
                    DisplayOrder = 4,
                    CreatedByUserId = System.Guid.Empty
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "SAFETY",
                    CategoryName = "Safety Equipment",
                    CategoryDescription = "PPE, SCBA, breathing apparatus, fall protection",
                    CategoryColor = "#FFFF00",
                    DisplayOrder = 5,
                    CreatedByUserId = System.Guid.Empty
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "SUPPORT",
                    CategoryName = "Support Equipment",
                    CategoryDescription = "Tools, lighting, communications, generators, ventilation",
                    CategoryColor = "#9900FF",
                    DisplayOrder = 6,
                    CreatedByUserId = System.Guid.Empty
                })
                .Row(new
                {
                    OperationalCategoryId = System.Guid.NewGuid(),
                    DepartmentId = 1,
                    CategoryCode = "TRAINING",
                    CategoryName = "Training",
                    CategoryDescription = "Training-only equipment and materials",
                    CategoryColor = "#999999",
                    DisplayOrder = 7,
                    CreatedByUserId = System.Guid.Empty
                });
        }

        public override void Down()
        {
            Delete.Table("AmbiparCategoryAssignments");
            Delete.Table("AmbiparOperationalCategories");
        }
    }
}
```

### 1.4 Configuration Setup

**File:** `/Core/Resgrid.Config/AmbiparConfig.cs`

```csharp
namespace Resgrid.Config
{
    public static class AmbiparConfig
    {
        // AI Provider Configuration
        public static string OpenAIApiKey { get; set; }
        public static string OpenAIOrganizationId { get; set; }
        public static string OpenAIModel { get; set; } = "gpt-4-turbo";

        public static string AzureOpenAIEndpoint { get; set; }
        public static string AzureOpenAIKey { get; set; }
        public static string AzureOpenAIDeployment { get; set; }

        public static string AnthropicApiKey { get; set; }
        public static string AnthropicModel { get; set; } = "claude-3-5-sonnet-20241022";

        public static string AIProviderType { get; set; } = "OpenAI"; // OpenAI, Azure, Anthropic

        // SharePoint Integration
        public static string SharePointSiteUrl { get; set; }
        public static string SharePointClientId { get; set; }
        public static string SharePointClientSecret { get; set; }
        public static string SharePointTenantId { get; set; }
        public static string SharePointDocumentLibrary { get; set; } = "Resgrid Documents";

        // Geotab Integration
        public static string GeotabServerUrl { get; set; } = "https://my.geotab.com";
        public static string GeotabDatabase { get; set; }
        public static string GeotabUsername { get; set; }
        public static string GeotabPassword { get; set; }
        public static int GeotabSyncIntervalMinutes { get; set; } = 5;

        // Replicon Integration
        public static string RepliconApiUrl { get; set; }
        public static string RepliconApiToken { get; set; }
        public static string RepliconCompanyKey { get; set; }
        public static bool RepliconAutoSync { get; set; } = true;

        // Microsoft 365 Integration
        public static string M365TenantId { get; set; }
        public static string M365ClientId { get; set; }
        public static string M365ClientSecret { get; set; }

        // Power Apps Integration
        public static string PowerAppsEnvironmentId { get; set; }
        public static string PowerAppsApiUrl { get; set; }

        // Compliance Settings
        public static bool EnableAutomatedComplianceChecks { get; set; } = true;
        public static int ComplianceWarningDays { get; set; } = 30;
        public static bool SendComplianceAlerts { get; set; } = true;

        // Performance Settings
        public static int AIRequestTimeoutSeconds { get; set; } = 30;
        public static int MaxAIRetryAttempts { get; set; } = 3;
        public static bool CacheAIResponses { get; set; } = true;
        public static int AIResponseCacheDurationMinutes { get; set; } = 60;

        // Feature Flags
        public static bool EnableAIDispatch { get; set; } = true;
        public static bool EnableHazmatIntelligence { get; set; } = true;
        public static bool EnableEquipmentPrediction { get; set; } = true;
        public static bool EnableNaturalLanguageQueries { get; set; } = true;
        public static bool EnableSharePointIntegration { get; set; } = true;
        public static bool EnableGeotabIntegration { get; set; } = true;
        public static bool EnableRepliconIntegration { get; set; } = true;
    }
}
```

**Environment Variables (`.env` additions):**
```bash
# -----------------------------------------------
# --- Ambipar AI Configuration ------------------
# -----------------------------------------------

AMBIPAR__OpenAIApiKey=sk-your-openai-api-key-here
AMBIPAR__OpenAIModel=gpt-4-turbo
AMBIPAR__AnthropicApiKey=sk-ant-your-anthropic-key-here
AMBIPAR__AnthropicModel=claude-3-5-sonnet-20241022
AMBIPAR__AIProviderType=OpenAI

# -----------------------------------------------
# --- Ambipar SharePoint Integration ------------
# -----------------------------------------------

AMBIPAR__SharePointSiteUrl=https://ambipar.sharepoint.com/sites/resgrid
AMBIPAR__SharePointClientId=your-client-id
AMBIPAR__SharePointClientSecret=your-client-secret
AMBIPAR__SharePointTenantId=your-tenant-id

# -----------------------------------------------
# --- Ambipar Geotab Integration ----------------
# -----------------------------------------------

AMBIPAR__GeotabServerUrl=https://my.geotab.com
AMBIPAR__GeotabDatabase=ambipar
AMBIPAR__GeotabUsername=your-geotab-username
AMBIPAR__GeotabPassword=your-geotab-password

# -----------------------------------------------
# --- Ambipar Replicon Integration --------------
# -----------------------------------------------

AMBIPAR__RepliconApiUrl=https://na2.replicon.com/ambipar/services
AMBIPAR__RepliconApiToken=your-replicon-token
AMBIPAR__RepliconCompanyKey=ambipar-company-key

# -----------------------------------------------
# --- Ambipar Feature Flags ---------------------
# -----------------------------------------------

AMBIPAR__EnableAIDispatch=true
AMBIPAR__EnableHazmatIntelligence=true
AMBIPAR__EnableGeotabIntegration=true
AMBIPAR__EnableRepliconIntegration=true
```

---

## PHASE 2: SEVEN OPERATIONAL CATEGORIES

**Duration:** 2 weeks
**Dependencies:** Phase 1 complete
**Risk:** Low

### 2.1 Category Implementation Strategy

**Approach:** Extend the existing `CustomState` system with Ambipar-specific operational categories.

**Benefits of This Approach:**
- Leverages existing Resgrid infrastructure
- Maintains compatibility with mobile apps
- Uses proven data model
- Minimal core code changes

### 2.2 Service Layer Implementation

**File:** `/Core/Resgrid.Model.Ambipar/Services/IOperationalCategoryService.cs`

```csharp
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Resgrid.Model.Ambipar.Entities;

namespace Resgrid.Model.Ambipar.Services
{
    /// <summary>
    /// Service interface for managing Ambipar's seven operational categories
    /// </summary>
    public interface IOperationalCategoryService
    {
        /// <summary>
        /// Get all operational categories for a department
        /// </summary>
        Task<List<OperationalCategory>> GetCategoriesForDepartmentAsync(int departmentId);

        /// <summary>
        /// Get a specific operational category by ID
        /// </summary>
        Task<OperationalCategory> GetCategoryByIdAsync(Guid categoryId);

        /// <summary>
        /// Get a category by its code (FIRE, MEDICAL, etc.)
        /// </summary>
        Task<OperationalCategory> GetCategoryByCodeAsync(int departmentId, string categoryCode);

        /// <summary>
        /// Assign a category to an entity (Unit, Personnel, Equipment, Call, etc.)
        /// </summary>
        Task<CategoryAssignment> AssignCategoryAsync(Guid categoryId, string entityType, int entityId, bool isPrimary, string notes, Guid assignedByUserId);

        /// <summary>
        /// Get all category assignments for an entity
        /// </summary>
        Task<List<CategoryAssignment>> GetCategoryAssignmentsAsync(string entityType, int entityId);

        /// <summary>
        /// Get all entities assigned to a category
        /// </summary>
        Task<List<CategoryAssignment>> GetEntitiesInCategoryAsync(Guid categoryId, string entityType = null);

        /// <summary>
        /// Remove a category assignment
        /// </summary>
        Task<bool> RemoveCategoryAssignmentAsync(Guid assignmentId);

        /// <summary>
        /// Get units by operational category
        /// </summary>
        Task<List<Unit>> GetUnitsByCategoryAsync(int departmentId, string categoryCode);

        /// <summary>
        /// Get personnel qualified for a category
        /// </summary>
        Task<List<DepartmentMember>> GetPersonnelByCategoryAsync(int departmentId, string categoryCode);

        /// <summary>
        /// Get equipment/inventory by category
        /// </summary>
        Task<List<Inventory>> GetInventoryByCategoryAsync(int departmentId, string categoryCode);

        /// <summary>
        /// Get calls by category
        /// </summary>
        Task<List<Call>> GetCallsByCategoryAsync(int departmentId, string categoryCode, DateTime? startDate, DateTime? endDate);

        /// <summary>
        /// Update category assignment (change primary status, notes, etc.)
        /// </summary>
        Task<CategoryAssignment> UpdateCategoryAssignmentAsync(Guid assignmentId, bool? isPrimary, string notes);

        /// <summary>
        /// Get category statistics for a department
        /// </summary>
        Task<CategoryStatistics> GetCategoryStatisticsAsync(int departmentId, DateTime? startDate, DateTime? endDate);

        /// <summary>
        /// Validate if personnel has required qualifications for a category
        /// </summary>
        Task<bool> ValidatePersonnelQualificationsAsync(Guid userId, string categoryCode);

        /// <summary>
        /// Get recommended categories for a call based on call type, priority, and nature
        /// </summary>
        Task<List<OperationalCategory>> GetRecommendedCategoriesForCallAsync(int callId);
    }
}
```

**Implementation File:** `/Core/Resgrid.Services.Ambipar/OperationalCategoryService.cs`

```csharp
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Resgrid.Model;
using Resgrid.Model.Ambipar.Entities;
using Resgrid.Model.Ambipar.Services;
using Resgrid.Model.Repositories;
using Microsoft.Extensions.Logging;
using Resgrid.Providers.Cache;

namespace Resgrid.Services.Ambipar
{
    public class OperationalCategoryService : IOperationalCategoryService
    {
        private readonly ILogger<OperationalCategoryService> _logger;
        private readonly IGenericDataRepository<OperationalCategory> _categoryRepository;
        private readonly IGenericDataRepository<CategoryAssignment> _assignmentRepository;
        private readonly IUnitsService _unitsService;
        private readonly IInventoryService _inventoryService;
        private readonly ICallsService _callsService;
        private readonly ICacheProvider _cacheProvider;

        public OperationalCategoryService(
            ILogger<OperationalCategoryService> logger,
            IGenericDataRepository<OperationalCategory> categoryRepository,
            IGenericDataRepository<CategoryAssignment> assignmentRepository,
            IUnitsService unitsService,
            IInventoryService inventoryService,
            ICallsService callsService,
            ICacheProvider cacheProvider)
        {
            _logger = logger;
            _categoryRepository = categoryRepository;
            _assignmentRepository = assignmentRepository;
            _unitsService = unitsService;
            _inventoryService = inventoryService;
            _callsService = callsService;
            _cacheProvider = cacheProvider;
        }

        public async Task<List<OperationalCategory>> GetCategoriesForDepartmentAsync(int departmentId)
        {
            var cacheKey = $"ambipar_categories_{departmentId}";

            var categories = await _cacheProvider.GetAsync<List<OperationalCategory>>(cacheKey);
            if (categories != null)
                return categories;

            categories = await _categoryRepository.GetAllAsync(c =>
                c.DepartmentId == departmentId && c.IsActive);

            await _cacheProvider.SetAsync(cacheKey, categories, TimeSpan.FromHours(1));

            return categories.OrderBy(c => c.DisplayOrder).ToList();
        }

        public async Task<OperationalCategory> GetCategoryByCodeAsync(int departmentId, string categoryCode)
        {
            var categories = await GetCategoriesForDepartmentAsync(departmentId);
            return categories.FirstOrDefault(c => c.CategoryCode.Equals(categoryCode, StringComparison.OrdinalIgnoreCase));
        }

        public async Task<CategoryAssignment> AssignCategoryAsync(
            Guid categoryId,
            string entityType,
            int entityId,
            bool isPrimary,
            string notes,
            Guid assignedByUserId)
        {
            try
            {
                // Check if assignment already exists
                var existing = await _assignmentRepository.GetFirstAsync(a =>
                    a.OperationalCategoryId == categoryId &&
                    a.EntityType == entityType &&
                    a.EntityId == entityId);

                if (existing != null)
                {
                    _logger.LogWarning($"Category assignment already exists: {categoryId} -> {entityType}:{entityId}");
                    return existing;
                }

                // If this is a primary assignment, unset any other primary assignments for this entity
                if (isPrimary)
                {
                    var existingAssignments = await GetCategoryAssignmentsAsync(entityType, entityId);
                    foreach (var assignment in existingAssignments.Where(a => a.IsPrimary))
                    {
                        assignment.IsPrimary = false;
                        await _assignmentRepository.UpdateAsync(assignment);
                    }
                }

                var newAssignment = new CategoryAssignment
                {
                    CategoryAssignmentId = Guid.NewGuid(),
                    OperationalCategoryId = categoryId,
                    EntityType = entityType,
                    EntityId = entityId,
                    IsPrimary = isPrimary,
                    Notes = notes,
                    AssignedOn = DateTime.UtcNow,
                    AssignedByUserId = assignedByUserId
                };

                await _assignmentRepository.InsertAsync(newAssignment);

                _logger.LogInformation($"Category assigned: {categoryId} -> {entityType}:{entityId} (Primary: {isPrimary})");

                // Clear cache
                await _cacheProvider.RemoveAsync($"ambipar_assignments_{entityType}_{entityId}");

                return newAssignment;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, $"Error assigning category: {categoryId} -> {entityType}:{entityId}");
                throw;
            }
        }

        public async Task<List<CategoryAssignment>> GetCategoryAssignmentsAsync(string entityType, int entityId)
        {
            var cacheKey = $"ambipar_assignments_{entityType}_{entityId}";

            var assignments = await _cacheProvider.GetAsync<List<CategoryAssignment>>(cacheKey);
            if (assignments != null)
                return assignments;

            assignments = await _assignmentRepository.GetAllAsync(a =>
                a.EntityType == entityType &&
                a.EntityId == entityId);

            await _cacheProvider.SetAsync(cacheKey, assignments, TimeSpan.FromMinutes(30));

            return assignments.OrderByDescending(a => a.IsPrimary).ThenBy(a => a.AssignedOn).ToList();
        }

        // Additional methods would be implemented here...
    }
}
```

### 2.3 Entity Models

**File:** `/Core/Resgrid.Model.Ambipar/Entities/OperationalCategory.cs`

```csharp
using System;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace Resgrid.Model.Ambipar.Entities
{
    /// <summary>
    /// Represents one of Ambipar's seven operational categories
    /// </summary>
    [Table("AmbiparOperationalCategories")]
    public class OperationalCategory
    {
        [Key]
        public Guid OperationalCategoryId { get; set; }

        public int DepartmentId { get; set; }

        [Required]
        [MaxLength(20)]
        public string CategoryCode { get; set; } // FIRE, MEDICAL, HAZMAT, RESCUE, SAFETY, SUPPORT, TRAINING

        [Required]
        [MaxLength(100)]
        public string CategoryName { get; set; }

        public string CategoryDescription { get; set; }

        [MaxLength(7)]
        public string CategoryColor { get; set; } // Hex color code

        public int DisplayOrder { get; set; }

        public bool IsActive { get; set; }

        public DateTime CreatedOn { get; set; }

        public Guid CreatedByUserId { get; set; }

        public DateTime? UpdatedOn { get; set; }

        public Guid? UpdatedByUserId { get; set; }

        [ForeignKey("DepartmentId")]
        public virtual Department Department { get; set; }
    }

    /// <summary>
    /// Assigns operational categories to entities (Units, Personnel, Equipment, Calls, etc.)
    /// </summary>
    [Table("AmbiparCategoryAssignments")]
    public class CategoryAssignment
    {
        [Key]
        public Guid CategoryAssignmentId { get; set; }

        public Guid OperationalCategoryId { get; set; }

        [Required]
        [MaxLength(50)]
        public string EntityType { get; set; } // 'Unit', 'Personnel', 'Inventory', 'Call', 'Protocol'

        public int EntityId { get; set; }

        public bool IsPrimary { get; set; }

        public string Notes { get; set; }

        public DateTime AssignedOn { get; set; }

        public Guid AssignedByUserId { get; set; }

        [ForeignKey("OperationalCategoryId")]
        public virtual OperationalCategory Category { get; set; }
    }

    /// <summary>
    /// Statistics for operational categories
    /// </summary>
    public class CategoryStatistics
    {
        public Guid CategoryId { get; set; }
        public string CategoryCode { get; set; }
        public string CategoryName { get; set; }
        public int TotalUnits { get; set; }
        public int TotalPersonnel { get; set; }
        public int TotalEquipment { get; set; }
        public int TotalCalls { get; set; }
        public int ActiveDeployments { get; set; }
        public decimal TotalResponseTimeMinutes { get; set; }
        public decimal AverageResponseTimeMinutes { get; set; }
    }
}
```

---

## PHASE 3: AI SERVICE LAYER

**Duration:** 4 weeks
**Dependencies:** Phase 1, 2 complete
**Risk:** Medium

This is the most complex phase. Detailed implementation in next section...

### 3.1 AI Service Architecture

**Service Structure:**
```
Resgrid.Providers.AI/
├── IAIProvider.cs (interface)
├── Providers/
│   ├── OpenAIProvider.cs
│   ├── AzureOpenAIProvider.cs
│   └── AnthropicProvider.cs
├── Models/
│   ├── AIRequest.cs
│   ├── AIResponse.cs
│   ├── DispatchRecommendation.cs
│   ├── HazmatAnalysis.cs
│   ├── EquipmentPrediction.cs
│   └── ComplianceValidation.cs
└── AIProviderModule.cs (Autofac)
```

*[Continued in following sections...]*

---

**END OF SECTION 1 - Implementation Plan continues with detailed Phase 3-7 specifications, API endpoints, testing strategy, and deployment guides.**

---

## QUICK REFERENCE

### Key Contacts
- **Project Lead:** [Name]
- **Technical Lead:** [Name]
- **Compliance Officer:** [Name]

### Repository
- **GitHub:** https://github.com/ambipar/resgrid-ambipar
- **Branch:** ambipar-main

### Environments
- **Development:** https://dev-resgrid.ambipar.ca
- **Staging:** https://staging-resgrid.ambipar.ca
- **Production:** https://resgrid.ambipar.ca

### Documentation
- Resgrid Core Docs: https://docs.resgrid.com
- Ambipar Custom Docs: `/Documentation/Ambipar/`
- API Documentation: https://resgrid.ambipar.ca/swagger

---

*Document Version: 1.0*
*Last Updated: November 2025*
*Status: Planning Phase - Awaiting Approval*
