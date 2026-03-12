# Mermaid Diagram Templates Reference

All 10 diagram types for Step 5.

## 1. High-Level Architecture
```mermaid
graph TB
    subgraph "Experience Layer"
        EXP[api-name-exp]
    end
    subgraph "Process Layer"
        PRC[api-name-prc]
    end
    subgraph "System Layer"
        SYS[api-name-sys]
    end
    subgraph "External Systems"
        SAP[SAP]
        SFDC[Salesforce]
    end
    EXP --> PRC
    PRC --> SYS
    SYS --> SAP
    SYS --> SFDC
```

## 2. Sequence Diagram (Success)
```mermaid
sequenceDiagram
    participant Client
    participant EXP as Experience API
    participant PRC as Process API
    participant SYS as System API
    participant Backend
    
    Client->>EXP: POST /resource
    EXP->>PRC: Transform & Route
    PRC->>SYS: Business Logic
    SYS->>Backend: Database/Service Call
    Backend-->>SYS: Response
    SYS-->>PRC: Processed Data
    PRC-->>EXP: Formatted Response
    EXP-->>Client: 200 OK
```

## 3. Sequence Diagram (Error)
```mermaid
sequenceDiagram
    participant Client
    participant EXP as Experience API
    participant PRC as Process API
    participant SYS as System API
    participant Backend
    
    Client->>EXP: POST /resource
    EXP->>PRC: Transform & Route
    PRC->>SYS: Business Logic
    SYS->>Backend: Database/Service Call
    Backend--xSYS: Error/Timeout
    SYS-->>PRC: Error Response
    PRC-->>EXP: Error Handling
    EXP-->>Client: 500 Error
    Note over EXP: Error logged with correlationId
```

## 4. Data Flow
```mermaid
flowchart LR
    subgraph Input
        REQ[Request Payload]
    end
    subgraph Transform1[EXP Transform]
        T1[Validate]
        T2[Enrich Headers]
    end
    subgraph Transform2[PRC Transform]
        T3[Business Rules]
        T4[Data Mapping]
    end
    subgraph Transform3[SYS Transform]
        T5[Protocol Convert]
        T6[Format Output]
    end
    subgraph Output
        RES[Response/Target]
    end
    REQ --> T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> RES
```

## 5. Header Propagation
```mermaid
flowchart LR
    subgraph Headers
        H1[RCorrelationId]
        H2[RSourceSystem]
        H3[RTargetSystem]
        H4[RBusinessKeys]
        H5[REventDateTime]
    end
    subgraph APIs
        A1[EXP API]
        A2[PRC API]
        A3[SYS API]
    end
    H1 --> A1 --> A2 --> A3
    H2 --> A1 --> A2 --> A3
    H3 --> A1 --> A2 --> A3
    H4 --> A1 --> A2 --> A3
    H5 --> A1 --> A2 --> A3
```

## 6. Logging Flow
```mermaid
flowchart TB
    subgraph API[MuleSoft API]
        START[START Trace Point]
        BEFORE_REQ[BEFORE_REQUEST]
        AFTER_REQ[AFTER_REQUEST]
        BEFORE_TRANS[BEFORE_TRANSFORM]
        AFTER_TRANS[AFTER_TRANSFORM]
        END_POINT[END Trace Point]
    end
    subgraph ELK[Elasticsearch]
        INDEX[mulesoft-pharma-env-*]
    end
    START --> BEFORE_REQ --> AFTER_REQ --> BEFORE_TRANS --> AFTER_TRANS --> END_POINT
    START --> INDEX
    BEFORE_REQ --> INDEX
    AFTER_REQ --> INDEX
    BEFORE_TRANS --> INDEX
    AFTER_TRANS --> INDEX
    END_POINT --> INDEX
```

## 7. Duration Tracking (Gantt)
```mermaid
gantt
    title API Transaction Duration
    dateFormat X
    axisFormat %L ms
    
    section EXP API
    Request Processing    :0, 50
    
    section PRC API
    Business Logic        :50, 150
    
    section SYS API
    Backend Call          :150, 400
    
    section Response
    Response Assembly     :400, 450
```

## 8. Error Handling
```mermaid
flowchart TB
    subgraph ErrorFlow[Error Handling Flow]
        ERR[Error Occurs]
        CATCH[Error Handler]
        LOG[Log Error]
        NOTIFY[Notification Service]
        RESP[Error Response]
    end
    subgraph ErrorTypes[Error Types]
        E1[CONNECTIVITY]
        E2[TIMEOUT]
        E3[VALIDATION]
        E4[BUSINESS]
    end
    ERR --> CATCH
    CATCH --> LOG
    CATCH --> NOTIFY
    CATCH --> RESP
    E1 --> ERR
    E2 --> ERR
    E3 --> ERR
    E4 --> ERR
```

## 9. Component Diagram
```mermaid
graph TB
    subgraph Components[API Components]
        LISTENER[HTTP Listener]
        ROUTER[APIKit Router]
        FLOWS[Business Flows]
        CONNECTOR[HTTP Request]
        LOGGER[JSON Logger]
        ERROR[Error Handler]
    end
    subgraph External
        CLIENT[Client]
        BACKEND[Backend System]
        ELK[Elasticsearch]
    end
    CLIENT --> LISTENER
    LISTENER --> ROUTER
    ROUTER --> FLOWS
    FLOWS --> CONNECTOR
    CONNECTOR --> BACKEND
    FLOWS --> LOGGER
    LOGGER --> ELK
    FLOWS --> ERROR
```

## 10. Deployment Diagram
```mermaid
graph TB
    subgraph CloudHub[Anypoint CloudHub]
        subgraph Workers[Worker Nodes]
            W1[Worker 1]
            W2[Worker 2]
        end
        subgraph Runtime[Mule Runtime]
            API[API Application]
        end
    end
    subgraph APIManager[API Manager]
        POLICY[Policies]
        SLA[SLA Tiers]
    end
    subgraph Monitoring
        ELK[Elasticsearch]
        KIBANA[Kibana]
    end
    APIManager --> CloudHub
    CloudHub --> Monitoring
```
