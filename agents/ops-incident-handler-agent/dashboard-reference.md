# HTML Dashboard Reference

Full specifications for Step 6: Generate HTML Dashboard.

## Dashboard Specifications

- **Theme:** Dark theme
  - Background: `#1a1b2e`
  - Cards: `#252840`
  - Accent: `#00bfb3`
- **No external dependencies** - All CSS embedded
- **File output:** Save as `transaction-dashboard-{correlation_id}.html`

## Required Sections

### 1. Header
- Title: "End-to-End Transaction Journey Dashboard"
- Search box showing correlation ID

### 2. Metrics Row (5 cards)
- Total Events count
- APIs Involved count
- Total Duration (first to last timestamp)
- Max Latency
- Overall Status (SUCCESS/FAILURE)

### 3. Business Context Panel
- Business keys as colored tags
- Table: Entity, Source System, Target System, Region, Data Classification
- Sample KQL query

### 4. Events by API Layer
- Horizontal bar chart
- Event count per API
- Color-coded dots

### 5. Transaction Timeline
- Chronological event list
- Columns: Time (HH:MM:SS.mmm), Application, Flow, Trace Point, Message, Elapsed
- Color-coded trace points:
  - START = green (#10b981)
  - END = cyan (#00bfb3)
  - BEFORE_REQUEST = blue (#3b82f6)
  - AFTER_REQUEST = orange (#f59e0b)
  - BEFORE_TRANSFORM = purple (#8b5cf6)
  - AFTER_TRANSFORM = purple (#8b5cf6)
  - EVENT = purple (#8b5cf6)
- Left-border timeline visual

### 6. Latency by API Layer
- Table showing max latency per API
- Sorted descending

### 7. API Flow Diagram
- Visual representation of data flow
- Source systems → Integration APIs → Target systems

## Log Fields to Extract

```
MuleMessage.applicationName
MuleMessage.correlationId
MuleMessage.tracePoint
MuleMessage.message
MuleMessage.timestamp
MuleMessage.elapsed
MuleMessage.locationInfo.rootContainer
sourceSystem
targetSystem
MuleMessage.metadata.entity
MuleMessage.metadata.dataClassificationType
MuleMessage.metadata.region
MuleMessage.metadata.businessKeys
```
