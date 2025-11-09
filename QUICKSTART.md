# AMBIPAR RESGRID - QUICK START GUIDE

**Version:** 1.0
**Date:** November 2025
**For:** Developers, System Administrators, DevOps Engineers

---

## TABLE OF CONTENTS

1. [Prerequisites](#prerequisites)
2. [Initial Setup](#initial-setup)
3. [Development Environment](#development-environment)
4. [Running the System](#running-the-system)
5. [Accessing Services](#accessing-services)
6. [Testing AI Features](#testing-ai-features)
7. [Common Tasks](#common-tasks)
8. [Troubleshooting](#troubleshooting)
9. [Next Steps](#next-steps)

---

## PREREQUISITES

### Required Software

| Software | Version | Purpose |
|----------|---------|---------|
| **Docker** | 24.0+ | Container runtime |
| **Docker Compose** | 2.20+ | Multi-container orchestration |
| **Git** | 2.40+ | Version control |
| **.NET SDK** | 8.0+ | Building C# applications |
| **Node.js** | 20 LTS | Frontend build tools |
| **PostgreSQL Client** | 16+ | Database management |
| **VS Code** or **Visual Studio** | Latest | IDE (recommended) |

### System Requirements

- **CPU:** 4+ cores (8+ recommended)
- **RAM:** 16GB minimum (32GB recommended)
- **Disk:** 50GB free space (SSD recommended)
- **OS:** Linux (Ubuntu 22.04+), macOS (13+), or Windows 11 with WSL2

### Cloud Accounts (For Full Functionality)

- [ ] **OpenAI Account** - For AI features (or Azure OpenAI / Anthropic)
- [ ] **Microsoft 365 Tenant** - For SharePoint, Teams integration
- [ ] **Geotab Account** - For fleet tracking integration
- [ ] **Replicon Account** - For timesheet integration

---

## INITIAL SETUP

### 1. Clone the Repository

```bash
# Clone the Ambipar-customized Resgrid repository
git clone https://github.com/ambipar/resgrid-ambipar.git
cd resgrid-ambipar

# Checkout the main branch
git checkout ambipar-main

# Alternatively, work with the base Resgrid + setup repo
cd /home/user/resgrid-setup
```

### 2. Configure Environment Variables

```bash
# Copy example environment files
cp .env.example .env
cp .env.ambipar.example .env.ambipar

# Edit configuration files with your settings
nano .env.ambipar
```

**Critical Settings to Configure:**

```bash
# AI Provider (choose one)
AMBIPAR__AIProviderType=OpenAI
AMBIPAR__OpenAIApiKey=sk-proj-YOUR-API-KEY-HERE

# Database
POSTGRES_USER=resgridUser
POSTGRES_PASSWORD=YOUR-SECURE-PASSWORD-HERE

# Redis
REDIS_PASSWORD=YOUR-REDIS-PASSWORD

# Application URLs (for local dev)
NGINX_RESGRID_WEB_URL=localhost
NGINX_RESGRID_API_URL=api.localhost
NGINX_RESGRID_EVENTS_URL=events.localhost
```

### 3. Set Up Local SSL Certificates (Optional for Development)

```bash
# Generate self-signed certificates for local development
cd docker-data/caddy
./generate-local-certs.sh

# OR use the existing certificates in the repo
# (Already configured in docker-compose.ambipar.yml)
```

### 4. Initialize Database

```bash
# Create required directories
mkdir -p docker-data/sql
mkdir -p docker-data/redis/data
mkdir -p docker-data/rabbitmq/data
mkdir -p logs/{web,api,events,ai,integrations,worker}

# Set permissions
chmod -R 755 docker-data
chmod -R 755 logs
```

---

## DEVELOPMENT ENVIRONMENT

### Visual Studio Code Setup

**Recommended Extensions:**

```json
{
  "recommendations": [
    "ms-dotnettools.csharp",
    "ms-azuretools.vscode-docker",
    "ms-vscode.powershell",
    "esbenp.prettier-vscode",
    "dbaeumer.vscode-eslint",
    "eamodio.gitlens",
    "humao.rest-client"
  ]
}
```

### VS Code Settings (`.vscode/settings.json`)

```json
{
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll": true
  },
  "files.exclude": {
    "**/bin": true,
    "**/obj": true,
    "**/node_modules": true
  },
  "dotnet.defaultSolution": "Resgrid.sln"
}
```

### Building from Source (Optional)

```bash
# Navigate to Resgrid Core
cd /home/user/resgrid-core

# Restore dependencies
dotnet restore Resgrid.sln

# Build solution
dotnet build Resgrid.sln --configuration Debug

# Run tests
dotnet test Tests/Resgrid.Tests/Resgrid.Tests.csproj

# Build Docker images (from your customizations)
docker-compose -f docker-compose.ambipar.yml build
```

---

## RUNNING THE SYSTEM

### Start All Services

```bash
# Using Docker Compose (recommended for development)
docker-compose -f docker-compose.ambipar.yml up -d

# View logs
docker-compose -f docker-compose.ambipar.yml logs -f

# View logs for specific service
docker-compose -f docker-compose.ambipar.yml logs -f api
```

### Service Startup Order

The system starts services in this order (automatically handled by `depends_on`):

1. **Infrastructure Layer** (30-60 seconds)
   - PostgreSQL (db)
   - Redis
   - RabbitMQ

2. **Core Services** (60-90 seconds)
   - Events Hub
   - AI Service (NEW)
   - Worker Service

3. **Application Layer** (30-60 seconds)
   - API Service
   - Integrations Service (NEW)
   - Web Application

4. **Gateway** (10-20 seconds)
   - Caddy Reverse Proxy

**Total Startup Time:** ~2-4 minutes

### Verify Services Are Running

```bash
# Check all containers
docker ps

# Check health status
docker-compose -f docker-compose.ambipar.yml ps

# Test endpoints
curl http://localhost:5151/health  # Web
curl http://localhost:5152/health  # API
curl http://localhost:5153/health  # Events
curl http://localhost:5154/health  # AI Service
curl http://localhost:5155/health  # Integrations
```

### Stop Services

```bash
# Stop all services
docker-compose -f docker-compose.ambipar.yml down

# Stop and remove volumes (WARNING: Deletes all data!)
docker-compose -f docker-compose.ambipar.yml down -v
```

---

## ACCESSING SERVICES

### Web Interfaces

| Service | URL | Credentials |
|---------|-----|-------------|
| **Resgrid Web App** | http://localhost:5151 | Create account on first run |
| **Resgrid API** | http://localhost:5152 | OAuth2 token required |
| **SignalR Events Hub** | http://localhost:5153 | WebSocket connection |
| **AI Service** | http://localhost:5154 | Internal service |
| **Integrations Service** | http://localhost:5155 | Internal service |
| **RabbitMQ Management** | http://localhost:5160 | resgrid / Resgrid321! |

### API Documentation

**Swagger UI:**
- http://localhost:5152/swagger

**API Endpoints:**

```
Base URL: http://localhost:5152/api/v4

Authentication:
POST /connect/token
  Body: { "grant_type": "password", "username": "...", "password": "..." }

Core Resources:
GET    /api/v4/calls              - List calls
POST   /api/v4/calls              - Create call
GET    /api/v4/personnel          - List personnel
GET    /api/v4/units              - List units
GET    /api/v4/groups             - List stations/groups

Ambipar AI Endpoints (NEW):
POST   /api/v4/ai/dispatch/analyze-personnel
POST   /api/v4/ai/hazmat/analyze
POST   /api/v4/ai/equipment/predict-failures
POST   /api/v4/ai/query           - Natural language queries

Ambipar Operational Categories (NEW):
GET    /api/v4/ambipar/categories
POST   /api/v4/ambipar/categories/assign
GET    /api/v4/ambipar/categories/{code}/entities

Compliance & Certifications (NEW):
GET    /api/v4/ambipar/compliance/requirements
GET    /api/v4/ambipar/compliance/expiring
POST   /api/v4/ambipar/compliance/validate
```

### Database Access

```bash
# Connect to PostgreSQL
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid

# Common queries
\dt                                    # List tables
\dt ambipar*                          # List Ambipar tables
SELECT * FROM "AmbiparOperationalCategories";
SELECT * FROM "AmbiparAIAnalysisResults" ORDER BY "CreatedOn" DESC LIMIT 10;

# Export data
docker exec resgrid-db-ambipar pg_dump -U resgridUser resgrid > backup.sql
```

### Redis Cache Access

```bash
# Connect to Redis
docker exec -it resgrid-redis-ambipar redis-cli -a resgrid123

# Common commands
KEYS ambipar:*                        # List Ambipar cache keys
GET ambipar:categories:1              # Get cached categories
FLUSHDB                               # Clear cache (development only!)
```

---

## TESTING AI FEATURES

### 1. Test Intelligent Dispatch

**Create a Test Call:**

```bash
curl -X POST http://localhost:5152/api/v4/calls \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Hazmat Spill - UN1203",
    "natureOfCall": "Chemical spill at industrial site. Gasoline leak from tanker truck. Approx 500L on ground.",
    "type": "HAZMAT",
    "priority": "High",
    "address": "12345 Industrial Way, Langley, BC",
    "latitude": 49.1044,
    "longitude": -122.5797
  }'
```

**Get AI Dispatch Recommendations:**

```bash
curl -X POST http://localhost:5152/api/v4/ai/dispatch/analyze-personnel \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "callId": 1,
    "considerAvailability": true,
    "considerProximity": true,
    "maxRecommendations": 5
  }'
```

**Expected Response:**

```json
{
  "callId": 1,
  "analysisTimestamp": "2025-11-09T10:30:00Z",
  "personnelRecommendations": [
    {
      "userId": "guid-here",
      "fullName": "John Smith",
      "role": "Hazmat Technician",
      "confidenceScore": 95.5,
      "reasoning": "Holds valid TDG certification, OFA3, and 8 years HAZMAT experience. Currently available and 12km from incident.",
      "estimatedResponseTimeMinutes": 18,
      "qualificationMatches": ["TDG", "OFA3", "HAZMAT Technician", "Confined Space"],
      "concerns": [],
      "distanceKm": 12.3,
      "currentStatus": "Available"
    }
  ],
  "aiReasoning": "Based on the hazmat nature (UN1203 - Gasoline), recommended personnel with TDG and HAZMAT certifications...",
  "providerUsed": "OpenAI",
  "modelUsed": "gpt-4-turbo",
  "tokensUsed": 1847,
  "processingTimeMs": 3241
}
```

### 2. Test Hazmat Intelligence

```bash
curl -X POST http://localhost:5152/api/v4/ai/hazmat/analyze \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type": application/json" \
  -d '{
    "unNumber": "1203",
    "shippingName": "Gasoline",
    "quantity": "500 liters",
    "locationDetails": "Outdoor paved surface, moderate wind, temperature 15°C"
  }'
```

**Response includes:**
- Chemical properties and hazards
- Required PPE (Level A/B/C/D)
- Decontamination protocols
- Exclusion zone distances (hot/warm/cold)
- TDG compliance requirements
- Environmental considerations

### 3. Test Natural Language Queries

```bash
curl -X POST http://localhost:5152/api/v4/ai/query \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "departmentId": 1,
    "query": "Who is on standby for HAZMAT response this week with valid TDG certification?"
  }'
```

### 4. Monitor AI Service Logs

```bash
# Watch AI service logs in real-time
docker logs -f resgrid-ai-ambipar

# Check for errors
docker logs resgrid-ai-ambipar | grep ERROR

# View AI analysis history
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid \
  -c "SELECT \"AnalysisType\", COUNT(*), AVG(\"TokensUsed\"), AVG(\"ProcessingTimeMs\")
      FROM \"AmbiparAIAnalysisResults\"
      WHERE \"CreatedOn\" > NOW() - INTERVAL '1 day'
      GROUP BY \"AnalysisType\";"
```

---

## COMMON TASKS

### Creating a New Department (Ambipar Organization)

```bash
# 1. Access the web application
open http://localhost:5151

# 2. Create admin account (first user becomes admin)
# 3. Navigate to Admin > Department Settings
# 4. Fill in Ambipar details:
#    - Name: Ambipar Response Canada Inc.
#    - Code: AMBIPAR-CA
#    - Time Zone: America/Vancouver
#    - Address: Langley, BC

# 5. Configure operational categories (automatically created via migration)
```

### Adding Personnel with Certifications

```sql
-- Connect to database
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid

-- Add compliance requirement (example: OFA3)
INSERT INTO "AmbiparComplianceRequirements" (
  "ComplianceRequirementId",
  "DepartmentId",
  "RequirementCode",
  "RequirementName",
  "RequirementType",
  "IssuingAuthority",
  "ValidityPeriodDays",
  "WarningDays",
  "IsMandatory",
  "AppliesTo",
  "IsActive",
  "CreatedOn",
  "CreatedByUserId"
) VALUES (
  gen_random_uuid(),
  1,
  'OFA3',
  'Occupational First Aid Level 3',
  'Certification',
  'WorkSafeBC',
  1095,
  30,
  TRUE,
  'Personnel',
  TRUE,
  NOW(),
  '00000000-0000-0000-0000-000000000000'
);

-- Add certification record for a user
INSERT INTO "AmbiparComplianceRecords" (
  "ComplianceRecordId",
  "ComplianceRequirementId",
  "DepartmentId",
  "EntityType",
  "EntityId",
  "CertificationNumber",
  "IssuedDate",
  "ExpiryDate",
  "Status",
  "CreatedOn",
  "CreatedByUserId"
) VALUES (
  gen_random_uuid(),
  (SELECT "ComplianceRequirementId" FROM "AmbiparComplianceRequirements" WHERE "RequirementCode" = 'OFA3' LIMIT 1),
  1,
  'Personnel',
  123,
  'OFA3-12345',
  '2024-01-15',
  '2027-01-15',
  'Current',
  NOW(),
  '00000000-0000-0000-0000-000000000000'
);
```

### Assigning Operational Categories

```bash
# Assign a unit to HAZMAT category
curl -X POST http://localhost:5152/api/v4/ambipar/categories/assign \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "categoryCode": "HAZMAT",
    "entityType": "Unit",
    "entityId": 5,
    "isPrimary": true,
    "notes": "Hazmat response unit with full decon equipment"
  }'

# Get all units in FIRE category
curl http://localhost:5152/api/v4/ambipar/categories/FIRE/entities?entityType=Unit \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Running Database Migrations

```bash
# Run migrations automatically (via worker on startup)
docker-compose -f docker-compose.ambipar.yml restart worker

# OR run manually
docker exec resgrid-worker-ambipar dotnet Resgrid.Workers.Console.dll --migrate

# Check migration status
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid \
  -c "SELECT * FROM \"VersionInfo\" ORDER BY \"Version\" DESC LIMIT 10;"
```

### Backing Up Data

```bash
# Full PostgreSQL backup
docker exec resgrid-db-ambipar pg_dump -U resgridUser resgrid > backup-$(date +%Y%m%d).sql

# Backup Redis data
docker exec resgrid-redis-ambipar redis-cli -a resgrid123 SAVE
cp docker-data/redis/data/dump.rdb backup-redis-$(date +%Y%m%d).rdb

# Backup uploaded files
tar -czf backup-uploads-$(date +%Y%m%d).tar.gz docker-data/uploads/
```

### Restoring Data

```bash
# Restore PostgreSQL backup
cat backup-20250109.sql | docker exec -i resgrid-db-ambipar psql -U resgridUser resgrid

# Restore Redis data
docker-compose -f docker-compose.ambipar.yml stop redis
cp backup-redis-20250109.rdb docker-data/redis/data/dump.rdb
docker-compose -f docker-compose.ambipar.yml start redis
```

---

## TROUBLESHOOTING

### Service Won't Start

**Problem:** Container exits immediately

```bash
# Check logs
docker logs resgrid-api-ambipar

# Common issues:
# 1. Database not ready - wait 30s and retry
# 2. Environment variable missing - check .env.ambipar
# 3. Port conflict - check if port already in use: lsof -i :5152
```

**Solution:**

```bash
# Restart individual service
docker-compose -f docker-compose.ambipar.yml restart api

# Rebuild and restart
docker-compose -f docker-compose.ambipar.yml up -d --build api
```

### Database Connection Errors

**Problem:** "Connection refused" or "password authentication failed"

```bash
# Check database is running
docker ps | grep resgrid-db

# Check database logs
docker logs resgrid-db-ambipar

# Verify credentials
docker exec resgrid-db-ambipar psql -U resgridUser -d resgrid -c "SELECT version();"

# Reset password if needed
docker exec -it resgrid-db-ambipar psql -U postgres \
  -c "ALTER USER resgridUser WITH PASSWORD 'NewPassword';"

# Update .env.ambipar with new password
```

### AI Service Not Responding

**Problem:** AI endpoints return 500 errors or timeout

```bash
# Check AI service logs
docker logs resgrid-ai-ambipar

# Common issues:
# 1. Invalid API key
grep "AMBIPAR__OpenAIApiKey" .env.ambipar

# 2. Rate limiting
# Check if you've exceeded OpenAI rate limits

# 3. Network connectivity
docker exec resgrid-ai-ambipar curl -I https://api.openai.com

# Test AI service directly
curl http://localhost:5154/health
```

**Solution:**

```bash
# Verify API key works
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"

# Restart AI service
docker-compose -f docker-compose.ambipar.yml restart ai

# Check AI analysis results table for errors
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid \
  -c "SELECT * FROM \"AmbiparAIAnalysisResults\"
      WHERE \"IsSuccessful\" = FALSE
      ORDER BY \"CreatedOn\" DESC LIMIT 5;"
```

### Redis Connection Issues

**Problem:** "Connection refused" or cache not working

```bash
# Check Redis is running
docker exec resgrid-redis-ambipar redis-cli -a resgrid123 PING
# Should return: PONG

# Check memory usage
docker exec resgrid-redis-ambipar redis-cli -a resgrid123 INFO memory

# Clear cache if corrupted
docker exec resgrid-redis-ambipar redis-cli -a resgrid123 FLUSHALL

# Restart Redis
docker-compose -f docker-compose.ambipar.yml restart redis
```

### RabbitMQ Not Processing Messages

**Problem:** Background jobs not running

```bash
# Check RabbitMQ is running
curl http://localhost:5160

# Login to RabbitMQ Management UI
# http://localhost:5160
# Username: resgrid
# Password: Resgrid321!

# Check for messages in queues
docker exec resgrid-rabbitmq-ambipar rabbitmqctl list_queues

# Restart worker service
docker-compose -f docker-compose.ambipar.yml restart worker

# Check worker logs
docker logs resgrid-worker-ambipar
```

### Performance Issues

**Problem:** Slow response times or high CPU usage

```bash
# Check resource usage
docker stats

# Check database connections
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid \
  -c "SELECT count(*) as connections, state
      FROM pg_stat_activity
      GROUP BY state;"

# Check slow queries
docker exec -it resgrid-db-ambipar psql -U resgridUser -d resgrid \
  -c "SELECT query, mean_exec_time, calls
      FROM pg_stat_statements
      ORDER BY mean_exec_time DESC
      LIMIT 10;"

# Optimize database
docker exec resgrid-db-ambipar vacuumdb -U resgridUser -d resgrid --analyze

# Clear Redis cache
docker exec resgrid-redis-ambipar redis-cli -a resgrid123 FLUSHDB
```

---

## NEXT STEPS

### For Developers

1. **Review Architecture Documents**
   - [AMBIPAR_IMPLEMENTATION_PLAN.md](./AMBIPAR_IMPLEMENTATION_PLAN.md)
   - [AI_SERVICE_ARCHITECTURE.md](./AI_SERVICE_ARCHITECTURE.md)

2. **Set Up Development Environment**
   - Configure VS Code with recommended extensions
   - Clone Resgrid Core repository: `/home/user/resgrid-core`
   - Build from source and run tests

3. **Start Implementing Features**
   - Phase 1: Database migrations (Operational Categories)
   - Phase 2: AI Service Layer
   - Phase 3: External Integrations

4. **Read Resgrid Documentation**
   - Official docs: https://docs.resgrid.com
   - API docs: http://localhost:5152/swagger
   - Explore existing codebase in `/home/user/resgrid-core`

### For System Administrators

1. **Production Deployment Planning**
   - Review security best practices
   - Plan backup and disaster recovery
   - Configure monitoring (Prometheus/Grafana)

2. **Integration Setup**
   - Configure SharePoint integration
   - Set up Geotab fleet tracking
   - Connect Replicon timesheet system
   - Set up Microsoft 365 integration

3. **User Training**
   - Create user documentation
   - Schedule training sessions
   - Set up support channels

### For Project Managers

1. **Review Implementation Plan**
   - Understand 7-phase approach
   - Assign resources to phases
   - Set milestones and deadlines

2. **Stakeholder Communication**
   - Demo AI features to stakeholders
   - Gather feedback from operations team
   - Plan phased rollout

3. **Compliance Review**
   - Verify WorkSafeBC requirements
   - Check Transport Canada TDG compliance
   - Review NFPA standards adherence

---

## RESOURCES

### Documentation

- **This Repository:** `/home/user/resgrid-setup/`
- **Resgrid Core:** `/home/user/resgrid-core/`
- **Resgrid Docs:** https://docs.resgrid.com
- **Docker Docs:** https://docs.docker.com
- **PostgreSQL Docs:** https://www.postgresql.org/docs/

### Support

- **GitHub Issues:** https://github.com/ambipar/resgrid-ambipar/issues
- **Internal Wiki:** [Your company wiki URL]
- **Slack Channel:** #resgrid-dev
- **Email:** resgrid-support@ambipar.ca

### API Keys & Credentials

- **OpenAI Dashboard:** https://platform.openai.com/api-keys
- **Azure Portal:** https://portal.azure.com
- **Anthropic Console:** https://console.anthropic.com
- **Microsoft 365 Admin:** https://admin.microsoft.com
- **Geotab MyAdmin:** https://my.geotab.com
- **Replicon:** https://na2.replicon.com/ambipar

---

## APPENDIX

### Useful Docker Commands

```bash
# View all containers (including stopped)
docker ps -a

# Remove stopped containers
docker-compose -f docker-compose.ambipar.yml rm

# View resource usage
docker stats

# Execute command in container
docker exec -it resgrid-api-ambipar /bin/bash

# Copy files from container
docker cp resgrid-api-ambipar:/app/logs/. ./logs/

# Prune unused resources
docker system prune -a
```

### Useful SQL Queries

```sql
-- Check operational categories
SELECT * FROM "AmbiparOperationalCategories"
WHERE "IsActive" = TRUE
ORDER BY "DisplayOrder";

-- Check category assignments
SELECT
  c."CategoryName",
  a."EntityType",
  COUNT(*) as "AssignmentCount"
FROM "AmbiparCategoryAssignments" a
JOIN "AmbiparOperationalCategories" c ON a."OperationalCategoryId" = c."OperationalCategoryId"
GROUP BY c."CategoryName", a."EntityType";

-- AI analysis statistics
SELECT
  "AnalysisType",
  COUNT(*) as "TotalAnalyses",
  AVG("TokensUsed") as "AvgTokens",
  AVG("ProcessingTimeMs") as "AvgProcessingMs",
  SUM(CASE WHEN "IsSuccessful" THEN 1 ELSE 0 END) as "SuccessCount"
FROM "AmbiparAIAnalysisResults"
WHERE "CreatedOn" > NOW() - INTERVAL '7 days'
GROUP BY "AnalysisType";

-- Expiring certifications
SELECT
  cr."RequirementName",
  cr."CertificationNumber",
  cr."ExpiryDate",
  (cr."ExpiryDate" - CURRENT_DATE) as "DaysUntilExpiry"
FROM "AmbiparComplianceRecords" cr
JOIN "AmbiparComplianceRequirements" req ON cr."ComplianceRequirementId" = req."ComplianceRequirementId"
WHERE cr."Status" = 'Current'
  AND cr."ExpiryDate" <= CURRENT_DATE + INTERVAL '30 days'
ORDER BY cr."ExpiryDate";
```

---

**Version:** 1.0
**Last Updated:** November 2025
**Maintained By:** Ambipar Resgrid Development Team

*For questions or issues, please contact the development team or create an issue on GitHub.*
