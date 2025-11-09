# AMBIPAR RESPONSE CANADA - CUSTOM RESGRID BUILD

> Industrial Emergency Response Platform with AI-Powered Operations

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![.NET](https://img.shields.io/badge/.NET-8.0-purple.svg)](https://dotnet.microsoft.com/)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue.svg)](https://www.docker.com/)
[![AI Powered](https://img.shields.io/badge/AI-OpenAI%20%7C%20Azure%20%7C%20Claude-green.svg)](https://openai.com/)

---

## OVERVIEW

This is a customized deployment of the open-source [Resgrid](https://github.com/Resgrid/Core) emergency response platform, specifically tailored for **Ambipar Response Canada Inc.**, an industrial emergency response company operating across Canada.

### Key Features

✅ **Seven Operational Categories System** - Fire, Medical, Hazmat, Rescue, Safety, Support, Training
✅ **AI-Powered Dispatch** - Intelligent personnel and unit recommendations
✅ **Hazmat Intelligence** - Chemical analysis, PPE recommendations, exclusion zones
✅ **Equipment Prediction** - Failure prediction and maintenance scheduling
✅ **Natural Language Queries** - Ask questions in plain English
✅ **Compliance Tracking** - WorkSafeBC, Transport Canada TDG, NFPA standards
✅ **External Integrations** - SharePoint, Geotab, Replicon, Microsoft 365
✅ **Offline Operations** - Remote site support with sync capabilities
✅ **Industrial Client Management** - Multi-client deployments and billing

---

## QUICK START

```bash
# 1. Clone repository
git clone https://github.com/ambipar/resgrid-ambipar.git
cd resgrid-ambipar

# 2. Configure environment
cp .env.example .env
cp .env.ambipar.example .env.ambipar
nano .env.ambipar  # Add your API keys

# 3. Start services
docker-compose -f docker-compose.ambipar.yml up -d

# 4. Access application
open http://localhost:5151
```

**Full instructions:** See [QUICKSTART.md](./QUICKSTART.md)

---

## DOCUMENTATION

| Document | Description |
|----------|-------------|
| **[QUICKSTART.md](./QUICKSTART.md)** | Get up and running in minutes |
| **[AMBIPAR_IMPLEMENTATION_PLAN.md](./AMBIPAR_IMPLEMENTATION_PLAN.md)** | Comprehensive implementation roadmap (18 weeks) |
| **[AI_SERVICE_ARCHITECTURE.md](./AI_SERVICE_ARCHITECTURE.md)** | AI service layer design and implementation |
| **[docker-compose.ambipar.yml](./docker-compose.ambipar.yml)** | Docker orchestration configuration |
| **[.env.ambipar](./.env.ambipar)** | Environment variables and feature flags |

---

## ARCHITECTURE

### System Components

```
┌─────────────────────────────────────────────────────────┐
│              Caddy Reverse Proxy (SSL)                  │
└───────┬──────────────┬──────────────┬─────────┬────────┘
        │              │              │         │
   ┌────▼───┐    ┌────▼────┐    ┌────▼────┐  ┌▼────────┐
   │  Web   │    │   API   │    │ SignalR │  │   AI    │
   │  App   │    │         │    │ Events  │  │ Service │
   └────┬───┘    └────┬────┘    └────┬────┘  └┬────────┘
        │              │              │         │
        └──────────────┴──────────────┴─────────┘
                       │
      ┌────────────────┼────────────────┐
      │                │                │
  ┌───▼────┐    ┌─────▼─────┐    ┌────▼────┐
  │ PostgreSQL │  │   Redis   │    │ RabbitMQ│
  └────────────┘  └───────────┘    └─────────┘
```

### Technology Stack

- **Backend:** ASP.NET Core 8.0, C# 12
- **Database:** PostgreSQL 16 (primary), Redis 7 (cache)
- **Message Queue:** RabbitMQ 3
- **AI:** OpenAI GPT-4, Azure OpenAI, Anthropic Claude
- **Frontend:** Razor Pages, SignalR (WebSocket)
- **Mobile:** Xamarin.Forms (iOS/Android)
- **Deployment:** Docker Compose
- **Reverse Proxy:** Caddy 2 with automatic HTTPS

---

## PROJECT STRUCTURE

```
resgrid-ambipar/
├── Core/
│   ├── Resgrid.Model/              # Domain entities
│   ├── Resgrid.Services/           # Business logic
│   ├── Resgrid.Model.Ambipar/      # Custom entities (NEW)
│   └── Resgrid.Services.Ambipar/   # Custom services (NEW)
├── Providers/
│   ├── Resgrid.Providers.AI/       # AI provider abstraction (NEW)
│   └── Resgrid.Providers.Ambipar.Integrations/  # External integrations (NEW)
├── Web/
│   ├── Resgrid.Web.Services/       # REST API
│   └── Resgrid.Web/                # Web application
├── Workers/
│   └── Resgrid.Workers.Console/    # Background jobs
├── Docker/
│   ├── docker-compose.ambipar.yml  # Deployment configuration
│   └── Dockerfiles/                # Container definitions
└── Documentation/
    ├── QUICKSTART.md
    ├── AMBIPAR_IMPLEMENTATION_PLAN.md
    └── AI_SERVICE_ARCHITECTURE.md
```

---

## SEVEN OPERATIONAL CATEGORIES

Ambipar operations are classified into seven core categories:

| Category | Code | Description | Examples |
|----------|------|-------------|----------|
| 🔥 **Fire** | `FIRE` | Fire suppression and wildfire | Structural fire, wildland fire, foam systems |
| 🏥 **Medical** | `MEDICAL` | EMS and patient care | OFA3, trauma response, patient transport |
| ☣️ **Hazmat** | `HAZMAT` | Hazardous materials | Chemical spills, TDG, decontamination |
| 🪢 **Rescue** | `RESCUE` | Technical rescue operations | Rope rescue, confined space, extrication |
| 🦺 **Safety** | `SAFETY` | Personal protective equipment | SCBA, PPE, fall protection, breathing apparatus |
| 🔧 **Support** | `SUPPORT` | Support equipment | Tools, lighting, generators, ventilation |
| 📚 **Training** | `TRAINING` | Training equipment | Training-only materials and equipment |

These categories are applied to:
- Equipment/Inventory
- Personnel qualifications
- Incident types
- Resource allocation
- Reporting structures

---

## AI CAPABILITIES

### 1. Intelligent Dispatch 🤖

AI analyzes incidents and recommends optimal personnel and units based on:
- Certifications and qualifications
- Availability and proximity
- Experience level and recent workload
- Response time estimation

```bash
POST /api/v4/ai/dispatch/analyze-personnel
{
  "callId": 123,
  "considerAvailability": true,
  "considerProximity": true,
  "maxRecommendations": 5
}
```

### 2. Hazmat Intelligence ☣️

Chemical database integration with:
- UN number lookup
- PPE requirement analysis
- Decontamination protocol recommendations
- Exclusion zone calculations
- Transport Canada TDG compliance

### 3. Equipment Prediction 🔧

Predict equipment failures using:
- Usage pattern analysis
- Maintenance history
- Failure mode analysis
- Lifecycle tracking

### 4. Natural Language Queries 💬

Ask questions in plain English:
- *"Who's on standby for HAZMAT this week?"*
- *"List expiring medical certifications in next 30 days"*
- *"What equipment is checked out from Langley station?"*

### 5. Compliance Checking ✅

Automated validation for:
- WorkSafeBC regulations
- Transport Canada TDG
- NFPA standards
- Personnel qualification requirements

---

## EXTERNAL INTEGRATIONS

### SharePoint 📄
- Document management (SOPs, training materials)
- QR code equipment tracking
- Inspection form data sync

### Microsoft 365 🌐
- Calendar sync for scheduling
- Teams notifications
- Email integration

### Geotab 🚗
- Real-time vehicle tracking
- Fleet management
- Response time optimization

### Replicon ⏱️
- Automated timesheet generation
- Billable hours tracking
- Payroll integration

---

## COMPLIANCE & CERTIFICATIONS

### Regulatory Frameworks

- **WorkSafeBC** (British Columbia)
- **Alberta OHS**
- **Saskatchewan Employment Act**
- **Transport Canada TDG**
- **NFPA Standards** (1006, 1670, 472, 1500)
- **CSA Standards** (Z1006, Z259)

### Tracked Certifications

- **Medical:** OFA1, OFA2, OFA3, EMR, PCP, ACP
- **Fire:** IFSAC, Pro-Board, NFPA certifications
- **Hazmat:** TDG, WHMIS 2015, Hazmat Technician
- **Rescue:** Confined Space (CSA Z1006), Rope Rescue, Fall Protection (CSA Z259), Swiftwater Rescue

---

## DEPLOYMENT

### Requirements

- Docker 24.0+
- Docker Compose 2.20+
- 16GB RAM minimum (32GB recommended)
- 50GB disk space
- Linux/macOS/Windows with WSL2

### Production Deployment

1. **Environment Configuration**
   ```bash
   cp .env.production.example .env
   # Configure production settings
   ```

2. **SSL Certificates**
   ```bash
   # Update Caddyfile for Let's Encrypt
   NGINX_LETSENCRYPT_EMAIL=admin@ambipar.ca
   ```

3. **Start Services**
   ```bash
   docker-compose -f docker-compose.ambipar.yml up -d
   ```

4. **Verify Health**
   ```bash
   docker-compose -f docker-compose.ambipar.yml ps
   curl https://resgrid.ambipar.ca/health
   ```

---

## DEVELOPMENT

### Prerequisites

- .NET SDK 8.0+
- Node.js 20 LTS
- Visual Studio or VS Code
- PostgreSQL 16+ client

### Build from Source

```bash
# Clone Resgrid Core
cd /home/user/resgrid-core

# Restore dependencies
dotnet restore Resgrid.sln

# Build
dotnet build Resgrid.sln --configuration Debug

# Run tests
dotnet test

# Build custom Docker images
docker-compose -f docker-compose.ambipar.yml build
```

### Running Locally

```bash
# Start infrastructure
docker-compose -f docker-compose.ambipar.yml up -d db redis rabbitmq

# Run API locally
cd Web/Resgrid.Web.Services
dotnet run

# Run web application
cd Web/Resgrid.Web
dotnet run
```

---

## API ENDPOINTS

### Core Resources

```
POST   /api/v4/connect/token          - OAuth2 authentication
GET    /api/v4/calls                  - List calls
POST   /api/v4/calls                  - Create call
GET    /api/v4/personnel              - List personnel
GET    /api/v4/units                  - List units
```

### Ambipar AI Endpoints (NEW)

```
POST   /api/v4/ai/dispatch/analyze-personnel
POST   /api/v4/ai/dispatch/analyze-units
POST   /api/v4/ai/hazmat/analyze
POST   /api/v4/ai/equipment/predict-failures
POST   /api/v4/ai/query
POST   /api/v4/ai/compliance/validate
```

### Operational Categories (NEW)

```
GET    /api/v4/ambipar/categories
POST   /api/v4/ambipar/categories/assign
GET    /api/v4/ambipar/categories/{code}/entities
```

### Compliance (NEW)

```
GET    /api/v4/ambipar/compliance/requirements
GET    /api/v4/ambipar/compliance/expiring
POST   /api/v4/ambipar/compliance/validate
```

**Full API documentation:** http://localhost:5152/swagger

---

## IMPLEMENTATION PHASES

| Phase | Duration | Status |
|-------|----------|--------|
| **Phase 1:** Foundation & Infrastructure | 2 weeks | 📋 Planning |
| **Phase 2:** Seven Operational Categories | 2 weeks | 📋 Planning |
| **Phase 3:** AI Service Layer | 4 weeks | 📋 Planning |
| **Phase 4:** External Integrations | 3 weeks | 📋 Planning |
| **Phase 5:** Compliance & Certification | 2 weeks | 📋 Planning |
| **Phase 6:** Reporting & Analytics | 2 weeks | 📋 Planning |
| **Phase 7:** Testing & Deployment | 3 weeks | 📋 Planning |

**Total Duration:** 18 weeks (4.5 months)

See [AMBIPAR_IMPLEMENTATION_PLAN.md](./AMBIPAR_IMPLEMENTATION_PLAN.md) for detailed breakdown.

---

## PERFORMANCE TARGETS

| Feature | Target | Actual | Status |
|---------|--------|--------|--------|
| AI Dispatch Recommendations | < 5s | TBD | 📋 Pending |
| Hazmat Intelligence Analysis | < 5s | TBD | 📋 Pending |
| Equipment Failure Prediction | < 10s | TBD | 📋 Pending |
| Natural Language Queries | < 3s | TBD | 📋 Pending |
| Incident Creation | < 2s | TBD | 📋 Pending |
| System Uptime | 99.5% | TBD | 📋 Pending |

---

## SUPPORT & RESOURCES

### Documentation

- **Resgrid Official Docs:** https://docs.resgrid.com
- **Ambipar Custom Docs:** [This repository]
- **API Documentation:** http://localhost:5152/swagger

### Support Channels

- **GitHub Issues:** https://github.com/ambipar/resgrid-ambipar/issues
- **Email:** resgrid-support@ambipar.ca
- **Slack:** #resgrid-dev

### External Resources

- **OpenAI API Docs:** https://platform.openai.com/docs
- **Docker Docs:** https://docs.docker.com
- **PostgreSQL Docs:** https://www.postgresql.org/docs/
- **ASP.NET Core Docs:** https://docs.microsoft.com/aspnet/core

---

## LICENSE

This project is based on [Resgrid Core](https://github.com/Resgrid/Core) which is licensed under the Apache License 2.0.

Custom Ambipar modifications are proprietary and confidential.

```
Copyright 2025 Ambipar Response Canada Inc.
Portions Copyright 2014-2024 Resgrid, LLC.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
```

See [LICENSE](./LICENSE) for full terms.

---

## ACKNOWLEDGMENTS

- **Resgrid Team** - For the excellent open-source platform
- **Ambipar Response Canada** - For operational requirements and domain expertise
- **OpenAI/Anthropic** - For AI capabilities

---

## PROJECT STATUS

**Version:** 1.0.0-planning
**Status:** 📋 Planning Phase
**Target Production Date:** Q2 2025

### Current Repository State

✅ Complete architectural analysis of Resgrid Core
✅ Comprehensive implementation plan created
✅ AI service layer architecture designed
✅ Docker Compose configuration prepared
✅ Database schema designed
✅ Environment configuration templates ready
✅ Quick Start Guide created

### Next Steps

1. Fork Resgrid Core repository
2. Begin Phase 1: Foundation & Infrastructure
3. Implement database migrations
4. Develop AI service layer
5. Build external integrations
6. Comprehensive testing
7. Production deployment

---

## CONTACT

**Project Lead:** [Name]
**Technical Lead:** [Name]
**Organization:** Ambipar Response Canada Inc.
**Location:** Langley, BC, Canada
**Email:** resgrid@ambipar.ca
**Website:** https://ambipar.ca

---

*Built with ❤️ for first responders and emergency services professionals*

**Last Updated:** November 2025
