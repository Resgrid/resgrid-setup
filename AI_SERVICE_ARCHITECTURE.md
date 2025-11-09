# AMBIPAR RESGRID - AI SERVICE LAYER ARCHITECTURE

**Version:** 1.0
**Status:** Design Phase
**Last Updated:** November 2025

---

## TABLE OF CONTENTS

1. [Overview](#overview)
2. [AI Provider Architecture](#ai-provider-architecture)
3. [Service Interfaces](#service-interfaces)
4. [AI Features Implementation](#ai-features-implementation)
5. [Data Models](#data-models)
6. [Integration Points](#integration-points)
7. [Performance & Caching](#performance--caching)
8. [Error Handling](#error-handling)
9. [Cost Management](#cost-management)
10. [Security & Privacy](#security--privacy)

---

## OVERVIEW

The AI Service Layer provides intelligent analysis and recommendations across all Resgrid operations for Ambipar Response Canada. This layer integrates with multiple AI providers (OpenAI, Azure OpenAI, Anthropic Claude) to deliver seven core capabilities:

### Seven AI Capabilities

1. **Intelligent Dispatch** - Personnel and unit recommendations
2. **Hazmat Intelligence** - Chemical analysis and protocol recommendations
3. **Equipment Prediction** - Failure prediction and maintenance scheduling
4. **Incident Analysis** - Auto-categorization and escalation recommendations
5. **Natural Language Queries** - Conversational data access
6. **Compliance Checking** - Regulatory validation
7. **Safety Recommendations** - Real-time safety protocols

### Performance Targets

| Feature | Target Response Time | SLA |
|---------|---------------------|-----|
| Intelligent Dispatch | < 5 seconds | 95% |
| Hazmat Intelligence | < 5 seconds | 95% |
| Equipment Prediction | < 10 seconds | 90% |
| Incident Analysis | < 5 seconds | 95% |
| Natural Language Queries | < 3 seconds | 95% |
| Compliance Checking | < 2 seconds | 98% |
| Safety Recommendations | < 3 seconds | 98% |

---

## AI PROVIDER ARCHITECTURE

### Provider Abstraction Layer

```
┌─────────────────────────────────────────────────────────┐
│                  IAIService (Resgrid)                   │
│  ┌─────────────────────────────────────────────────┐   │
│  │         Core AI Service Interface               │   │
│  │  • AnalyzeForDispatch()                        │   │
│  │  • AnalyzeHazmat()                             │   │
│  │  • PredictEquipmentMaintenance()               │   │
│  │  • AnalyzeIncident()                           │   │
│  │  • ProcessNaturalLanguageQuery()               │   │
│  │  • ValidateCompliance()                        │   │
│  │  • GetSafetyRecommendations()                  │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │                           │
┌───────▼──────┐         ┌──────────▼──────────┐
│IAIProvider   │         │ Provider Selection  │
│(Interface)   │         │ Strategy            │
└───────┬──────┘         └──────────┬──────────┘
        │                           │
 ┌──────┴────────┬─────────────────┴──────────┐
 │               │                             │
┌▼────────────┐ ┌▼─────────────┐   ┌─────────▼────────┐
│  OpenAI     │ │ Azure OpenAI │   │   Anthropic      │
│  Provider   │ │  Provider    │   │   Provider       │
└─────────────┘ └──────────────┘   └──────────────────┘
```

### Provider Selection Strategy

**Decision Tree:**
```
IF RequiresVisionAnalysis THEN
    → Use GPT-4 Vision or Claude 3 Opus
ELSE IF RequiresLongContext (>100k tokens) THEN
    → Use Claude 3.5 Sonnet
ELSE IF RequiresFunctionCalling THEN
    → Use GPT-4 Turbo or Claude 3.5 Sonnet
ELSE IF BudgetConstrained THEN
    → Use GPT-3.5 Turbo or Claude 3 Haiku
ELSE
    → Use configured default provider
END IF
```

---

## SERVICE INTERFACES

### Core AI Service Interface

**File:** `/Core/Resgrid.Model.Ambipar/Services/IAIService.cs`

```csharp
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Resgrid.Model;
using Resgrid.Model.Ambipar.AI;

namespace Resgrid.Model.Ambipar.Services
{
    /// <summary>
    /// AI-powered operations service for Ambipar Resgrid
    /// </summary>
    public interface IAIService
    {
        #region Intelligent Dispatch

        /// <summary>
        /// Analyze a call and recommend optimal personnel for dispatch
        /// </summary>
        /// <param name="callId">Call ID to analyze</param>
        /// <param name="considerAvailability">Filter by personnel availability</param>
        /// <param name="considerProximity">Factor in geographical proximity</param>
        /// <param name="maxRecommendations">Maximum number of recommendations</param>
        /// <param name="cancellationToken">Cancellation token</param>
        /// <returns>Dispatch recommendations with reasoning</returns>
        Task<DispatchRecommendationResult> AnalyzeForPersonnelDispatchAsync(
            int callId,
            bool considerAvailability = true,
            bool considerProximity = true,
            int maxRecommendations = 10,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Recommend optimal units/equipment for a call
        /// </summary>
        Task<DispatchRecommendationResult> AnalyzeForUnitDispatchAsync(
            int callId,
            bool considerAvailability = true,
            int maxRecommendations = 5,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Calculate estimated response times for personnel/units to a location
        /// </summary>
        Task<ResponseTimeEstimation> EstimateResponseTimesAsync(
            int callId,
            List<Guid> personnelIds = null,
            List<int> unitIds = null,
            CancellationToken cancellationToken = default);

        #endregion

        #region Hazmat Intelligence

        /// <summary>
        /// Analyze hazardous materials based on UN number, shipping name, or description
        /// </summary>
        /// <param name="unNumber">UN identification number</param>
        /// <param name="shippingName">Proper shipping name</param>
        /// <param name="description">Substance description</param>
        /// <param name="quantity">Quantity involved</param>
        /// <param name="locationDetails">Location and environmental factors</param>
        /// <param name="cancellationToken">Cancellation token</param>
        /// <returns>Hazmat analysis with PPE recommendations and protocols</returns>
        Task<HazmatAnalysisResult> AnalyzeHazmatAsync(
            string unNumber = null,
            string shippingName = null,
            string description = null,
            string quantity = null,
            string locationDetails = null,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Get PPE recommendations for a hazmat incident
        /// </summary>
        Task<PPERecommendation> GetHazmatPPERecommendationsAsync(
            int callId,
            string substanceInfo,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Calculate exclusion zones for hazmat incidents
        /// </summary>
        Task<ExclusionZoneCalculation> CalculateExclusionZonesAsync(
            string unNumber,
            string quantity,
            string weatherConditions,
            decimal latitude,
            decimal longitude,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Validate Transport Canada TDG compliance
        /// </summary>
        Task<ComplianceValidationResult> ValidateTDGComplianceAsync(
            int callId,
            string shippingDocumentation,
            CancellationToken cancellationToken = default);

        #endregion

        #region Equipment Prediction & Maintenance

        /// <summary>
        /// Predict equipment failures based on usage patterns
        /// </summary>
        /// <param name="unitId">Unit ID to analyze</param>
        /// <param name="inventoryId">Inventory/equipment ID to analyze</param>
        /// <param name="lookAheadDays">Prediction horizon in days</param>
        /// <param name="cancellationToken">Cancellation token</param>
        /// <returns>Failure prediction with confidence scores</returns>
        Task<EquipmentPredictionResult> PredictEquipmentFailuresAsync(
            int? unitId = null,
            int? inventoryId = null,
            int lookAheadDays = 90,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Generate maintenance schedule recommendations
        /// </summary>
        Task<MaintenanceScheduleRecommendation> RecommendMaintenanceScheduleAsync(
            int departmentId,
            DateTime startDate,
            DateTime endDate,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Forecast inventory demand
        /// </summary>
        Task<InventoryDemandForecast> ForecastInventoryDemandAsync(
            int departmentId,
            int inventoryTypeId,
            int forecastDays = 90,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Identify equipment at risk of expiration/certification lapse
        /// </summary>
        Task<List<ExpiringEquipmentAlert>> GetExpiringEquipmentAlertsAsync(
            int departmentId,
            int warningDays = 30,
            CancellationToken cancellationToken = default);

        #endregion

        #region Incident Analysis

        /// <summary>
        /// Auto-categorize incident by type and severity
        /// </summary>
        /// <param name="callId">Call ID to analyze</param>
        /// <param name="cancellationToken">Cancellation token</param>
        /// <returns>Incident classification with operational category recommendations</returns>
        Task<IncidentClassificationResult> ClassifyIncidentAsync(
            int callId,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Recommend incident escalation based on patterns
        /// </summary>
        Task<EscalationRecommendation> AnalyzeForEscalationAsync(
            int callId,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Identify safety risks in an incident
        /// </summary>
        Task<SafetyRiskAnalysis> IdentifySafetyRisksAsync(
            int callId,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Generate incident summary and reports
        /// </summary>
        Task<IncidentSummary> GenerateIncidentSummaryAsync(
            int callId,
            bool includeTimeline = true,
            bool includeResourceUsage = true,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Perform trend analysis on incidents
        /// </summary>
        Task<IncidentTrendAnalysis> AnalyzeIncidentTrendsAsync(
            int departmentId,
            DateTime startDate,
            DateTime endDate,
            string categoryFilter = null,
            CancellationToken cancellationToken = default);

        #endregion

        #region Natural Language Queries

        /// <summary>
        /// Process natural language queries against Resgrid data
        /// </summary>
        /// <param name="departmentId">Department context</param>
        /// <param name="query">Natural language query (e.g., "Who's on standby for HAZMAT?")</param>
        /// <param name="userId">User making the query (for permissions)</param>
        /// <param name="cancellationToken">Cancellation token</param>
        /// <returns>Query result with structured data and explanation</returns>
        Task<NaturalLanguageQueryResult> ProcessNaturalLanguageQueryAsync(
            int departmentId,
            string query,
            Guid userId,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Get query suggestions based on user role and common patterns
        /// </summary>
        Task<List<string>> GetQuerySuggestionsAsync(
            int departmentId,
            Guid userId,
            string partialQuery = null,
            CancellationToken cancellationToken = default);

        #endregion

        #region Compliance Checking

        /// <summary>
        /// Validate WorkSafeBC regulation compliance
        /// </summary>
        Task<ComplianceValidationResult> ValidateWorkSafeBCComplianceAsync(
            int callId,
            List<Guid> personnelIds,
            List<int> equipmentIds,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Check NFPA standard compliance
        /// </summary>
        Task<ComplianceValidationResult> ValidateNFPAComplianceAsync(
            int departmentId,
            string nfpaStandard, // e.g., "1006", "472", "1500"
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Identify expiring certifications and recommend training
        /// </summary>
        Task<CertificationExpiryReport> GetExpiringCertificationsAsync(
            int departmentId,
            int warningDays = 30,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Validate personnel qualifications for a specific operation
        /// </summary>
        Task<QualificationValidationResult> ValidatePersonnelQualificationsAsync(
            Guid userId,
            string operationType, // e.g., "Confined Space Entry", "Hazmat Response"
            CancellationToken cancellationToken = default);

        #endregion

        #region Safety Recommendations

        /// <summary>
        /// Get real-time safety protocols based on incident type
        /// </summary>
        Task<SafetyProtocolRecommendation> GetSafetyProtocolsAsync(
            int callId,
            string incidentType,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Get environmental hazard warnings (weather, terrain)
        /// </summary>
        Task<EnvironmentalHazardWarning> GetEnvironmentalHazardsAsync(
            decimal latitude,
            decimal longitude,
            DateTime? dateTime = null,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Optimize route considering safety factors
        /// </summary>
        Task<SafeRouteRecommendation> GetSafeRouteRecommendationAsync(
            decimal fromLatitude,
            decimal fromLongitude,
            decimal toLatitude,
            decimal toLongitude,
            string hazardType = null,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Monitor personnel safety during incidents
        /// </summary>
        Task<PersonnelSafetyAlert> MonitorPersonnelSafetyAsync(
            int callId,
            List<Guid> personnelIds,
            CancellationToken cancellationToken = default);

        #endregion

        #region Utility Methods

        /// <summary>
        /// Get AI analysis history for an entity
        /// </summary>
        Task<List<AIAnalysisResult>> GetAnalysisHistoryAsync(
            string entityType,
            int entityId,
            string analysisType = null,
            int maxResults = 50,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Regenerate or refresh a previous AI analysis
        /// </summary>
        Task<AIAnalysisResult> RegenerateAnalysisAsync(
            Guid analysisResultId,
            CancellationToken cancellationToken = default);

        /// <summary>
        /// Provide feedback on AI recommendation accuracy
        /// </summary>
        Task RecordFeedbackAsync(
            Guid analysisResultId,
            bool wasAccurate,
            bool wasHelpful,
            string feedbackComments = null,
            CancellationToken cancellationToken = default);

        #endregion
    }
}
```

---

## AI FEATURES IMPLEMENTATION

### 1. Intelligent Dispatch Implementation

**File:** `/Core/Resgrid.Services.Ambipar/AI/DispatchAnalysisService.cs`

```csharp
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Resgrid.Model;
using Resgrid.Model.Ambipar.AI;
using Resgrid.Model.Ambipar.Services;
using Resgrid.Providers.AI;
using Microsoft.Extensions.Logging;

namespace Resgrid.Services.Ambipar.AI
{
    /// <summary>
    /// AI-powered dispatch analysis and recommendations
    /// </summary>
    public class DispatchAnalysisService
    {
        private readonly ILogger<DispatchAnalysisService> _logger;
        private readonly IAIProvider _aiProvider;
        private readonly ICallsService _callsService;
        private readonly IUserProfileService _userProfileService;
        private readonly ICertificationService _certificationService;
        private readonly IOperationalCategoryService _categoryService;
        private readonly IUnitsService _unitsService;
        private readonly IGeoLocationService _geoLocationService;

        public DispatchAnalysisService(
            ILogger<DispatchAnalysisService> logger,
            IAIProvider aiProvider,
            ICallsService callsService,
            IUserProfileService userProfileService,
            ICertificationService certificationService,
            IOperationalCategoryService categoryService,
            IUnitsService unitsService,
            IGeoLocationService geoLocationService)
        {
            _logger = logger;
            _aiProvider = aiProvider;
            _callsService = callsService;
            _userProfileService = userProfileService;
            _certificationService = certificationService;
            _categoryService = categoryService;
            _unitsService = unitsService;
            _geoLocationService = geoLocationService;
        }

        public async Task<DispatchRecommendationResult> AnalyzeForPersonnelDispatchAsync(
            int callId,
            bool considerAvailability,
            bool considerProximity,
            int maxRecommendations,
            CancellationToken cancellationToken)
        {
            try
            {
                _logger.LogInformation($"Starting AI dispatch analysis for call {callId}");

                // 1. Get call details
                var call = await _callsService.GetCallByIdAsync(callId);
                if (call == null)
                    throw new ArgumentException($"Call {callId} not found");

                // 2. Get all available personnel
                var allPersonnel = await _userProfileService.GetAllProfilesForDepartmentAsync(call.DepartmentId);

                // 3. Filter by availability if requested
                if (considerAvailability)
                {
                    var availablePersonnel = await FilterByAvailabilityAsync(allPersonnel);
                    allPersonnel = availablePersonnel;
                }

                // 4. Get certifications for all personnel
                var personnelWithCerts = await EnrichWithCertificationsAsync(allPersonnel);

                // 5. Calculate proximity if requested
                if (considerProximity && call.Latitude.HasValue && call.Longitude.HasValue)
                {
                    await CalculateProximityScoresAsync(personnelWithCerts, call.Latitude.Value, call.Longitude.Value);
                }

                // 6. Build AI prompt
                var prompt = BuildDispatchPrompt(call, personnelWithCerts, considerAvailability, considerProximity);

                // 7. Call AI provider
                var aiRequest = new AIRequest
                {
                    Prompt = prompt,
                    SystemMessage = GetDispatchSystemMessage(),
                    MaxTokens = 2000,
                    Temperature = 0.3, // Lower temperature for more deterministic results
                    FunctionDefinitions = GetDispatchFunctionDefinitions()
                };

                var aiResponse = await _aiProvider.GenerateCompletionAsync(aiRequest, cancellationToken);

                // 8. Parse AI response into structured recommendations
                var recommendations = ParseDispatchRecommendations(aiResponse, personnelWithCerts);

                // 9. Rank and limit recommendations
                var topRecommendations = recommendations
                    .OrderByDescending(r => r.ConfidenceScore)
                    .Take(maxRecommendations)
                    .ToList();

                _logger.LogInformation($"AI dispatch analysis complete: {topRecommendations.Count} recommendations generated");

                return new DispatchRecommendationResult
                {
                    CallId = callId,
                    AnalysisTimestamp = DateTime.UtcNow,
                    PersonnelRecommendations = topRecommendations,
                    AIReasoning = aiResponse.Content,
                    ProviderUsed = aiResponse.Provider,
                    ModelUsed = aiResponse.Model,
                    TokensUsed = aiResponse.TokensUsed,
                    ProcessingTimeMs = aiResponse.ProcessingTimeMs
                };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, $"Error during AI dispatch analysis for call {callId}");
                throw;
            }
        }

        private string BuildDispatchPrompt(
            Call call,
            List<PersonnelWithCertifications> personnel,
            bool considerAvailability,
            bool considerProximity)
        {
            var sb = new StringBuilder();

            sb.AppendLine("# EMERGENCY DISPATCH ANALYSIS REQUEST");
            sb.AppendLine();
            sb.AppendLine("You are an AI assistant for Ambipar Response Canada, an industrial emergency response company.");
            sb.AppendLine("Analyze this emergency call and recommend the most qualified personnel for dispatch.");
            sb.AppendLine();

            sb.AppendLine("## CALL DETAILS");
            sb.AppendLine($"**Call Number:** {call.Number}");
            sb.AppendLine($"**Type:** {call.Type}");
            sb.AppendLine($"**Priority:** {call.Priority}");
            sb.AppendLine($"**Nature of Call:** {call.NatureOfCall}");
            sb.AppendLine($"**Location:** {call.Address}");
            if (call.Latitude.HasValue && call.Longitude.HasValue)
                sb.AppendLine($"**Coordinates:** {call.Latitude}, {call.Longitude}");
            sb.AppendLine($"**Reported:** {call.LoggedOn:yyyy-MM-dd HH:mm}");
            sb.AppendLine();

            sb.AppendLine("## AVAILABLE PERSONNEL");
            foreach (var person in personnel)
            {
                sb.AppendLine($"### {person.Profile.FullName}");
                sb.AppendLine($"- **ID:** {person.Profile.UserId}");
                sb.AppendLine($"- **Role:** {person.Profile.Role}");

                if (person.Certifications.Any())
                {
                    sb.AppendLine("- **Certifications:**");
                    foreach (var cert in person.Certifications)
                    {
                        var status = cert.ExpiryDate.HasValue && cert.ExpiryDate < DateTime.UtcNow ? " ⚠️ EXPIRED" : "";
                        sb.AppendLine($"  - {cert.CertificationName} (Expires: {cert.ExpiryDate:yyyy-MM-dd}){status}");
                    }
                }

                if (considerAvailability)
                {
                    sb.AppendLine($"- **Current Status:** {person.CurrentStatus}");
                }

                if (considerProximity && person.ProximityKm.HasValue)
                {
                    sb.AppendLine($"- **Distance from Incident:** {person.ProximityKm:F1} km");
                }

                sb.AppendLine();
            }

            sb.AppendLine("## INSTRUCTIONS");
            sb.AppendLine("Based on the call details and personnel qualifications, recommend the TOP personnel for this dispatch.");
            sb.AppendLine();
            sb.AppendLine("Consider:");
            sb.AppendLine("1. **Required Certifications** - Personnel must have valid certifications for the incident type");
            sb.AppendLine("2. **Experience Level** - More experienced personnel for complex incidents");
            sb.AppendLine("3. **Proximity** - Closer personnel can respond faster");
            sb.AppendLine("4. **Availability** - Only recommend available personnel");
            sb.AppendLine("5. **Workload Balance** - Consider recent dispatch frequency");
            sb.AppendLine();
            sb.AppendLine("For each recommendation, provide:");
            sb.AppendLine("- Personnel ID");
            sb.AppendLine("- Confidence score (0-100)");
            sb.AppendLine("- Reasoning for recommendation");
            sb.AppendLine("- Estimated response time");
            sb.AppendLine("- Any concerns or warnings");
            sb.AppendLine();
            sb.AppendLine("Respond in JSON format using the provided function schema.");

            return sb.ToString();
        }

        private string GetDispatchSystemMessage()
        {
            return @"You are an expert emergency dispatch coordinator AI for Ambipar Response Canada.
Your role is to analyze emergency calls and recommend optimal personnel for dispatch based on:
- Certifications and qualifications (OFA, HAZMAT, TDG, Confined Space, Rope Rescue, etc.)
- Canadian safety regulations (WorkSafeBC, Transport Canada, NFPA standards)
- Operational categories (Fire, Medical, Hazmat, Rescue, Safety, Support, Training)
- Personnel availability and location
- Incident severity and complexity
- Response time requirements

Always prioritize safety, regulatory compliance, and operational effectiveness.
Provide clear reasoning for each recommendation.
Flag any compliance concerns or qualification gaps.";
        }

        // Additional helper methods...
    }
}
```

### 2. Hazmat Intelligence Implementation

**Key Features:**
- UN number lookup and chemical database integration
- PPE requirement analysis based on chemical properties
- Decontamination protocol recommendations
- Exclusion zone calculations (hot/warm/cold zones)
- Transport Canada TDG compliance validation
- Emergency Response Guidebook (ERG) integration

**Implementation Approach:**
```csharp
public async Task<HazmatAnalysisResult> AnalyzeHazmatAsync(
    string unNumber,
    string shippingName,
    string description,
    string quantity,
    string locationDetails,
    CancellationToken cancellationToken)
{
    // 1. Look up chemical in database (UN number database)
    var chemical = await LookupChemicalAsync(unNumber, shippingName);

    // 2. Build comprehensive context for AI
    var context = BuildHazmatContext(chemical, quantity, locationDetails);

    // 3. Query AI for analysis
    var aiPrompt = $@"
# HAZMAT INCIDENT ANALYSIS

## Substance Information
- UN Number: {unNumber}
- Proper Shipping Name: {shippingName}
- Description: {description}
- Quantity: {quantity}

## Location
{locationDetails}

## Chemical Properties
{chemical.Properties}

## Required Analysis
1. PPE Requirements (specific equipment by risk level)
2. Decontamination Protocols
3. Exclusion Zones (hot/warm/cold - provide distances)
4. Transport Canada TDG Compliance Check
5. Environmental Hazards
6. First Aid Measures
7. Containment Strategies
8. Neutralization Options (if applicable)

Provide detailed, actionable recommendations suitable for industrial emergency responders.";

    var aiResponse = await _aiProvider.GenerateCompletionAsync(
        new AIRequest { Prompt = aiPrompt, Temperature = 0.2 },
        cancellationToken);

    // 4. Parse and structure response
    return ParseHazmatAnalysis(aiResponse, chemical);
}
```

### 3. Equipment Prediction Implementation

**Machine Learning Approach:**

```
Historical Data → Feature Engineering → ML Model → Predictions
     ↓                    ↓                  ↓           ↓
  Usage logs       Extract features    Train model   Failure risk
  Maintenance     - Usage frequency   (Classification) scores
  Failure history - Last service date  or (Regression) Maintenance
  Age             - Hours/km           AI + Statistics  schedule
```

**AI-Assisted Implementation:**
```csharp
public async Task<EquipmentPredictionResult> PredictEquipmentFailuresAsync(
    int? unitId,
    int? inventoryId,
    int lookAheadDays,
    CancellationToken cancellationToken)
{
    // 1. Gather historical data
    var usageHistory = await GetEquipmentUsageHistoryAsync(unitId, inventoryId);
    var maintenanceHistory = await GetMaintenanceHistoryAsync(unitId, inventoryId);
    var failureHistory = await GetFailureHistoryAsync(unitId, inventoryId);

    // 2. Calculate statistical features
    var features = new
    {
        DaysSinceLastMaintenance = (DateTime.UtcNow - maintenanceHistory.LastDate).TotalDays,
        AverageUsagePerDay = usageHistory.TotalHours / usageHistory.DaysTracked,
        FailureFrequency = failureHistory.Count / (double)usageHistory.DaysTracked,
        AgeInYears = usageHistory.AgeYears,
        TotalOperatingHours = usageHistory.TotalHours,
        RecentUsageIntensity = usageHistory.RecentUsageRate / usageHistory.HistoricalAverageRate
    };

    // 3. Ask AI to analyze patterns and predict
    var aiPrompt = $@"
# EQUIPMENT FAILURE PREDICTION ANALYSIS

## Equipment Details
- Type: {usageHistory.EquipmentType}
- Age: {features.AgeInYears} years
- Total Operating Hours: {features.TotalOperatingHours}

## Usage Patterns
- Average daily usage: {features.AverageUsagePerDay:F2} hours
- Recent usage intensity: {features.RecentUsageIntensity:F2}x normal

## Maintenance History
- Last maintenance: {features.DaysSinceLastMaintenance} days ago
- Maintenance frequency: {maintenanceHistory.AverageIntervalDays} days
- Overdue: {features.DaysSinceLastMaintenance > maintenanceHistory.RecommendedIntervalDays}

## Failure History
- Historical failure rate: {features.FailureFrequency:F4} failures/day
- Last failure: {failureHistory.DaysSinceLastFailure} days ago
- Common failure modes: {string.Join(", ", failureHistory.CommonFailureModes)}

## Request
Predict the likelihood of equipment failure in the next {lookAheadDays} days.
Provide:
1. Failure risk score (0-100)
2. Most likely failure mode
3. Recommended maintenance actions
4. Urgency level (Low/Medium/High/Critical)
5. Confidence level in prediction";

    var aiResponse = await _aiProvider.GenerateCompletionAsync(
        new AIRequest { Prompt = aiPrompt, Temperature = 0.3 },
        cancellationToken);

    return ParseEquipmentPrediction(aiResponse, features);
}
```

---

## DATA MODELS

### AI Request/Response Models

**File:** `/Providers/Resgrid.Providers.AI/Models/AIRequest.cs`

```csharp
using System.Collections.Generic;

namespace Resgrid.Providers.AI.Models
{
    /// <summary>
    /// Request to AI provider
    /// </summary>
    public class AIRequest
    {
        /// <summary>
        /// Main prompt/user message
        /// </summary>
        public string Prompt { get; set; }

        /// <summary>
        /// System message defining AI behavior and context
        /// </summary>
        public string SystemMessage { get; set; }

        /// <summary>
        /// Maximum tokens to generate
        /// </summary>
        public int MaxTokens { get; set; } = 1000;

        /// <summary>
        /// Temperature (0.0 = deterministic, 1.0 = creative)
        /// </summary>
        public double Temperature { get; set; } = 0.7;

        /// <summary>
        /// Function/tool definitions for function calling
        /// </summary>
        public List<FunctionDefinition> FunctionDefinitions { get; set; }

        /// <summary>
        /// Force specific function to be called
        /// </summary>
        public string ForcedFunctionName { get; set; }

        /// <summary>
        /// Additional metadata for request tracking
        /// </summary>
        public Dictionary<string, string> Metadata { get; set; }
    }

    public class AIResponse
    {
        public string Content { get; set; }
        public string Provider { get; set; }
        public string Model { get; set; }
        public int TokensUsed { get; set; }
        public int ProcessingTimeMs { get; set; }
        public bool IsSuccessful { get; set; }
        public string ErrorMessage { get; set; }
        public FunctionCall FunctionCall { get; set; }
    }

    public class FunctionDefinition
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public Dictionary<string, object> Parameters { get; set; }
    }

    public class FunctionCall
    {
        public string Name { get; set; }
        public string Arguments { get; set; }
    }
}
```

### Dispatch Recommendation Models

**File:** `/Core/Resgrid.Model.Ambipar/AI/DispatchRecommendation.cs`

```csharp
using System;
using System.Collections.Generic;

namespace Resgrid.Model.Ambipar.AI
{
    public class DispatchRecommendationResult
    {
        public int CallId { get; set; }
        public DateTime AnalysisTimestamp { get; set; }
        public List<PersonnelRecommendation> PersonnelRecommendations { get; set; }
        public List<UnitRecommendation> UnitRecommendations { get; set; }
        public string AIReasoning { get; set; }
        public string ProviderUsed { get; set; }
        public string ModelUsed { get; set; }
        public int TokensUsed { get; set; }
        public int ProcessingTimeMs { get; set; }
    }

    public class PersonnelRecommendation
    {
        public Guid UserId { get; set; }
        public string FullName { get; set; }
        public string Role { get; set; }
        public decimal ConfidenceScore { get; set; } // 0-100
        public string Reasoning { get; set; }
        public int EstimatedResponseTimeMinutes { get; set; }
        public List<string> QualificationMatches { get; set; }
        public List<string> Concerns { get; set; }
        public double? DistanceKm { get; set; }
        public string CurrentStatus { get; set; }
    }

    public class UnitRecommendation
    {
        public int UnitId { get; set; }
        public string UnitName { get; set; }
        public string UnitType { get; set; }
        public decimal ConfidenceScore { get; set; }
        public string Reasoning { get; set; }
        public int EstimatedResponseTimeMinutes { get; set; }
        public List<string> EquipmentCapabilities { get; set; }
        public List<string> Concerns { get; set; }
        public double? DistanceKm { get; set; }
        public string CurrentStatus { get; set; }
    }

    public class ResponseTimeEstimation
    {
        public int CallId { get; set; }
        public List<PersonnelResponseTime> PersonnelResponseTimes { get; set; }
        public List<UnitResponseTime> UnitResponseTimes { get; set; }
    }

    public class PersonnelResponseTime
    {
        public Guid UserId { get; set; }
        public string FullName { get; set; }
        public int EstimatedMinutes { get; set; }
        public double DistanceKm { get; set; }
        public string TransportMethod { get; set; } // Personal vehicle, station response, etc.
    }

    public class UnitResponseTime
    {
        public int UnitId { get; set; }
        public string UnitName { get; set; }
        public int EstimatedMinutes { get; set; }
        public double DistanceKm { get; set; }
        public string RouteConditions { get; set; }
    }
}
```

*[Additional model definitions for Hazmat, Equipment Prediction, Incident Analysis, NL Queries, Compliance, and Safety would follow the same pattern]*

---

## INTEGRATION POINTS

### Integration with Existing Resgrid Services

```
CallsService → IAIService.ClassifyIncidentAsync()
             → IAIService.AnalyzeForPersonnelDispatchAsync()
             → IAIService.AnalyzeForUnitDispatchAsync()

DispatchController → IAIService (on call creation/assignment)

UnitsService → IAIService.PredictEquipmentFailuresAsync()

ComplianceService → IAIService.ValidateWorkSafeBCComplianceAsync()
                  → IAIService.GetExpiringCertificationsAsync()

HazmatModule → IAIService.AnalyzeHazmatAsync()
             → IAIService.GetHazmatPPERecommendationsAsync()

NaturalLanguageQueryController → IAIService.ProcessNaturalLanguageQueryAsync()
```

### API Endpoints for AI Features

**New Controller:** `/Web/Resgrid.Web.Services/Controllers/v4/AIController.cs`

```
POST   /api/v4/ai/dispatch/analyze-personnel
POST   /api/v4/ai/dispatch/analyze-units
POST   /api/v4/ai/dispatch/estimate-response-times

POST   /api/v4/ai/hazmat/analyze
POST   /api/v4/ai/hazmat/ppe-recommendations
POST   /api/v4/ai/hazmat/exclusion-zones
POST   /api/v4/ai/hazmat/tdg-compliance

POST   /api/v4/ai/equipment/predict-failures
POST   /api/v4/ai/equipment/maintenance-schedule
POST   /api/v4/ai/equipment/demand-forecast

POST   /api/v4/ai/incident/classify
POST   /api/v4/ai/incident/escalation-analysis
POST   /api/v4/ai/incident/safety-risks
POST   /api/v4/ai/incident/summary
POST   /api/v4/ai/incident/trends

POST   /api/v4/ai/query
GET    /api/v4/ai/query/suggestions

POST   /api/v4/ai/compliance/worksafebc
POST   /api/v4/ai/compliance/nfpa
GET    /api/v4/ai/compliance/expiring-certifications
POST   /api/v4/ai/compliance/validate-qualifications

POST   /api/v4/ai/safety/protocols
POST   /api/v4/ai/safety/environmental-hazards
POST   /api/v4/ai/safety/route-recommendation
POST   /api/v4/ai/safety/personnel-monitoring

GET    /api/v4/ai/history/{entityType}/{entityId}
POST   /api/v4/ai/regenerate/{analysisId}
POST   /api/v4/ai/feedback/{analysisId}
```

---

## PERFORMANCE & CACHING

### Caching Strategy

```
Level 1: Redis Cache (Hot Data)
├── AI responses (TTL: 1 hour)
├── Chemical database lookups (TTL: 24 hours)
├── Personnel certifications (TTL: 1 hour)
└── Equipment usage stats (TTL: 15 minutes)

Level 2: PostgreSQL (Persistent Storage)
└── AmbiparAIAnalysisResults table (all historical analyses)

Level 3: Provider Response Cache
└── Identical prompt + context = cached response (TTL: 30 minutes)
```

**Cache Keys:**
```
ai:dispatch:{callId}:personnel:{hash}
ai:dispatch:{callId}:units:{hash}
ai:hazmat:un:{unNumber}
ai:equipment:failure:{unitId}:{inventoryId}
ai:nl:query:{departmentId}:{hash}
```

### Performance Optimization

1. **Parallel AI Calls:** When multiple analyses needed, execute in parallel
2. **Prompt Optimization:** Minimize token usage while maintaining accuracy
3. **Result Streaming:** Stream AI responses for better UX
4. **Background Processing:** Queue non-urgent analyses via RabbitMQ
5. **Circuit Breaker:** Prevent cascade failures if AI provider is down

---

## COST MANAGEMENT

### Token Usage Tracking

```sql
SELECT
    AnalysisType,
    COUNT(*) as TotalCalls,
    SUM(TokensUsed) as TotalTokens,
    AVG(TokensUsed) as AvgTokens,
    SUM(TokensUsed) * 0.00001 as EstimatedCostUSD -- Example rate
FROM AmbiparAIAnalysisResults
WHERE CreatedOn >= NOW() - INTERVAL '30 days'
GROUP BY AnalysisType
ORDER BY TotalTokens DESC;
```

### Cost Optimization Strategies

1. **Caching:** Reduce duplicate AI calls
2. **Prompt Engineering:** Minimize input tokens
3. **Model Selection:** Use cheaper models when appropriate
   - GPT-3.5-turbo for simple queries
   - GPT-4-turbo for complex analysis
   - Claude Haiku for high-volume, simple tasks
4. **Batching:** Batch multiple analyses in single request
5. **Sampling:** For testing, use subset of data
6. **Monitoring:** Alert when daily cost exceeds threshold

---

*[Document continues with Security, Error Handling, Testing, and Implementation Guides...]*

---

**END OF AI SERVICE ARCHITECTURE**
