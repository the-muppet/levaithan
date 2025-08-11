# LevAIthan Data Flow Diagrams

This document provides detailed views of how data flows through the LevAIthan system.

### 📊 InteractionEnvelope Message Flow

This diagram shows how ACP messages flow through the system:

```mermaid
flowchart TD
    Start(["InteractionEnvelope Message Flow"]) --> Parse["Parse ACP Message"]
    Parse --> Route{"Route by Type"}
    Route -- task_declaration --> PreWorkflow["Pre-Tool-Use Workflow"]
    Route -- completion_report --> PostWorkflow["Post-Tool-Use Workflow"]
    Route -- delegation_request --> DelegationWorkflow["Delegation Workflow"]
    Route -- human_correction --> CorrectionWorkflow["Human Correction Workflow"]
```
---

## 🔄 Knowledge Accumulation Cycle

This shows how the system learns and improves over time:

```mermaid
---
config:
  layout: elk
---
flowchart TB
 subgraph subGraph0["Data Sources"]
        A["Agent Activities"]
        B["Code Diffs"]
        C["Performance Metrics"]
        D["Cost Data"]
        E["Human Feedback"]
  end
 subgraph subGraph1["Collection & Storage"]
        F["activity_log Index"]
        G["PostgreSQL Tables"]
        H["Prometheus Metrics"]
        I["HelixDB Relationships"]
  end
 subgraph subGraph2["Analysis Engine"]
        J["Pattern Recognition"]
        K["Performance Analysis"]
        L["Cost Optimization"]
        M["Context Effectiveness"]
  end
 subgraph subGraph3["Knowledge Products"]
        N["Code Patterns"]
        O["Context Sources"]
        P["Performance Baselines"]
        Q["Budget Allocations"]
  end
 subgraph subGraph4["System Improvements"]
        R["Hook Optimizations"]
        S["Configuration Updates"]
        T["New Patterns"]
        U["Better Context"]
  end
    A --> F
    B --> G
    C --> H
    D --> G
    E --> G
    F --> J
    G --> K
    H --> K
    I --> M
    J --> N
    K --> P
    L --> Q
    M --> O
    N --> T
    O --> U
    P --> R
    Q --> S
    R --> A
    S --> A
    T --> A
    U --> A

```

## 🗄️ Database Interaction Patterns

This diagram shows how different types of data flow to appropriate databases:

```mermaid
---
config:
  layout: dagre
  theme: neo-dark
---
flowchart TD
 subgraph subGraph0["Data Types"]
        A["Structured Facts"]
        B["Relationships"]
        C["Time-Series Data"]
        D["Semantic Vectors"]
        E["Full-Text Logs"]
        F["Temporary State"]
  end
 subgraph subGraph1["Database Selection Logic"]
        G["data-access.sh Router"]
  end
 subgraph subGraph2["Storage Layer"]
        H[("PostgreSQL")]
        I[("HelixDB")]
        J[("Prometheus")]
        K[("Weaviate")]
        L[("Elasticsearch")]
        M[("Redis")]
  end
 subgraph subGraph3["Example Data"]
        N["Tasks, Sessions, Costs"]
        O["Agent → Task → File"]
        P["Hook Duration, Error Rates"]
        Q["Code Pattern Embeddings"]
        R["Agent Activity Logs"]
        S["Workflow State"]
  end
    A --> G
    B --> G
    C --> G
    D --> G
    E --> G
    F --> G
    G -- ACID Transactions --> H
    G -- Graph Queries --> I
    G -- Metrics & Alerts --> J
    G -- Similarity Search --> K
    G -- "Full-Text Search" --> L
    G -- Temporary Data --> M
    H --- N
    I --- O
    J --- P
    K --- Q
    L --- R
    M --- S
    style G fill:#FFEB3B,color:#000
    style H fill:#4CAF50,color:#fff
    style I fill:#2196F3,color:#fff
    style J fill:#FF9800,color:#fff
    style K fill:#9C27B0,color:#fff
    style L fill:#F44336,color:#fff
    style M fill:#795548,color:#fff

```

## 🚦 Resource Lock Management

This sequence shows how resource conflicts are prevented:

```mermaid
---
config:
  theme: redux-dark-color
---
sequenceDiagram
    participant A1 as Agent 1
    participant A2 as Agent 2
    participant Orch as Orchestrator
    participant Locks as Resource Locks
    participant DB as PostgreSQL
    Note over A1,A2: Both want to modify the same file
    A1->>Orch: "declare_task(target_files: [\"auth.js\"])"
    A2->>Orch: "declare_task(target_files: [\"auth.js\"])"
    par Agent 1 Flow
        Orch->>Locks: coord-acquire-lock.sh (session_1, "auth.js")
        Locks->>DB: INSERT resource_locks (session_1, "auth.js")
        DB-->>Locks: SUCCESS
        Locks-->>Orch: Lock acquired
        Note over Orch: Agent 1 proceeds with task
    and Agent 2 Flow
        Orch->>Locks: coord-acquire-lock.sh (session_2, "auth.js")
        Locks->>DB: INSERT resource_locks (session_2, "auth.js")
        DB-->>Locks: CONFLICT (UNIQUE constraint violation)
        Locks-->>Orch: Lock failed - resource in use
        Note over Orch: Agent 2 task blocked
    end
    Note over A1: Agent 1 completes work
    A1->>Orch: "report_completion()"
    Orch->>Locks: coord-release-lock.sh (session_1)
    Locks->>DB: DELETE FROM resource_locks WHERE session_id = 'session_1'
    Note over A2: Agent 2 can now retry
    A2->>Orch: "declare_task(target_files: [\"auth.js\"]) [retry]"
    Orch->>Locks: coord-acquire-lock.sh (session_2, "auth.js")
    Locks->>DB: INSERT resource_locks (session_2, "auth.js")
    DB-->>Locks: SUCCESS
    Note over A2: Agent 2 now proceeds
```

## 💰 Cost Tracking & Budget Enforcement

This shows how financial controls work throughout the system:
```mermaid
---
config:
  theme: neo-dark
  layout: elk
---
flowchart TB
 subgraph BudgetValidation["Budget Validation Process"]
        GetCurrentSpend@{ label: "Query cost_records table<br>for today's agent spending" }
        BudgetCheck["governance-check-budget.sh"]
        GetBudgetLimit@{ label: "Query budget_allocations table<br>for agent's daily limit" }
        CalculateRemaining["Calculate remaining budget:<br>limit - current_spend"]
        BudgetDecision{"Current Spend &lt; Budget Limit?"}
        BudgetApproved["Budget Check Passed"]
        BudgetBlocked["Budget Exceeded - Task Blocked"]
  end
 subgraph CostCalculation["Cost Calculation Process"]
        CountTokens["Count Input/Output Tokens<br>from task execution"]
        CostCalc["cost-calculate-and-log.sh"]
        CalculateCost["Calculate total cost<br>using token pricing"]
        StoreCost["Insert into cost_records table<br>with agent_id, task_id, timestamp"]
  end
 subgraph BudgetMonitoring["Automated Budget Monitoring"]
        DailyAggregation["Sum costs by agent<br>for current day"]
        TriggerMonitoring["Trigger Budget Monitoring"]
        CheckThreshold{"Approaching budget limit?<br>(&gt;80% of allocation)"}
        AlertHuman["Send alert to Human Operator<br>via notification system"]
        ContinueMonitoring["Continue normal operations"]
        HumanDecision["Human Decision Required"]
        BudgetAction{"Increase Budget or<br>Block Further Tasks?"}
        UpdateBudget["Update budget_allocations table<br>with new limit"]
        BlockAgent["Set agent status to blocked<br>until next day reset"]
  end
 subgraph BudgetSetup["Budget Administration"]
        SetBudgets["Configure daily budgets<br>via system-cli.sh"]
        HumanOperator["Human Operator"]
        UpdateAllocations["Insert/Update budget_allocations table<br>with agent limits"]
  end
    Start(["Agent ACP Message"]) --> Parse{"Parse Event Type"}
    Parse -- task_declaration --> PreWorkflow["Pre-Tool-Use Workflow"]
    PreWorkflow --> Ethics["governance-check-ethics.sh"]
    Ethics --> BudgetCheck
    BudgetCheck --> GetCurrentSpend
    GetCurrentSpend --> GetBudgetLimit
    GetBudgetLimit --> CalculateRemaining
    CalculateRemaining --> BudgetDecision
    BudgetDecision -- Yes --> BudgetApproved
    BudgetDecision -- No --> BudgetBlocked
    BudgetApproved --> Security["governance-check-permissions.sh"]
    Security --> CreateSession["coord-create-session.sh"]
    CreateSession --> AcquireLocks["coord-acquire-lock.sh"]
    AcquireLocks --> FindContext["context-find-similar.sh"]
    FindContext --> InjectContext["context-inject-final.sh"]
    InjectContext --> ApproveSession["coord-approve-session.sh"]
    ApproveSession --> Success(["Agent Proceeds with Task"])
    Success --> TaskExecution["Agent Executes Task"]
    TaskExecution --> PostWorkflow["Post-Tool-Use Workflow"]
    PostWorkflow --> CostCalc
    CostCalc --> CountTokens
    CountTokens --> CalculateCost
    CalculateCost --> StoreCost
    StoreCost --> TriggerMonitoring & ExtractKnowledge["knowledge-extract-from-diff.sh"]
    TriggerMonitoring --> DailyAggregation
    DailyAggregation --> CheckThreshold
    CheckThreshold -- Yes --> AlertHuman
    CheckThreshold -- No --> ContinueMonitoring
    AlertHuman --> HumanDecision
    HumanDecision --> BudgetAction
    BudgetAction -- Increase --> UpdateBudget
    BudgetAction -- Block --> BlockAgent
    HumanOperator --> SetBudgets
    SetBudgets --> UpdateAllocations
    BudgetBlocked --> ErrorCleanup["Emergency Cleanup"]
    Ethics -- Fail --> ErrorCleanup
    Security -- Fail --> ErrorCleanup
    AcquireLocks -- Fail --> ErrorCleanup
    ErrorCleanup --> Failed(["Task Failed"])
    UpdateAllocations -.-> GetBudgetLimit
    UpdateBudget -.-> GetBudgetLimit
    BlockAgent -.-> BudgetCheck
    ExtractKnowledge --> UpdateEffectiveness["context-update-effectiveness.sh"]
    UpdateEffectiveness --> ReleaseLocks["coord-release-lock.sh"]
    ReleaseLocks --> CloseSession["coord-close-session.sh"]
    CloseSession --> Complete(["Task Complete"])
    GetCurrentSpend@{ shape: rect}
    GetBudgetLimit@{ shape: rect}
    style BudgetDecision fill:#FF9800,color:#fff
    style BudgetApproved fill:#4CAF50,color:#fff
    style BudgetBlocked fill:#f44336,color:#fff
    style CheckThreshold fill:#FF9800,color:#fff
    style AlertHuman fill:#FF9800,color:#fff
    style HumanDecision fill:#2196F3,color:#fff
    style BudgetAction fill:#FF9800,color:#fff
    style Parse fill:#FF9800,color:#fff
    style Success fill:#4CAF50,color:#fff
    style Failed fill:#f44336,color:#fff
    style Complete fill:#4CAF50,color:#fff
```

## 🧠 Context Injection & Effectiveness Tracking

This diagram shows how the system learns which context is most helpful:

```mermaid
---
config:
  theme: neo-dark
  layout: dagre
---
flowchart LR
 subgraph subGraph0["Context Sources"]
        A["Code Patterns DB"]
        B["Documentation"]
        C["Previous Solutions"]
        D["Dependency Graph"]
  end
 subgraph subGraph1["Context Selection"]
        E["Agent Objective"]
        F["Semantic Similarity"]
        G["Historical Effectiveness"]
        H["Context Ranking"]
  end
 subgraph subGraph2["Task Execution"]
        I["Context Injection"]
        J["Agent Performance"]
        K["Task Outcome"]
  end
 subgraph subGraph3["Learning Loop"]
        L["Effectiveness Scoring"]
        M["Pattern Updates"]
        N["Source Weighting"]
  end
    A --> F
    B --> F
    C --> F
    D --> F
    E --> F
    F --> G
    G --> H
    H --> I
    I --> J
    J --> K
    K --> L
    L --> M
    M --> N
    N --> G
    style I fill:#FFEB3B,color:#000

```

## 🔄 Self-Improvement Feedback Loop

This shows the complete cycle of system evolution:

```mermaid
---
config:
  layout: elk
  theme: neo-dark
---
flowchart TB
 subgraph subGraph0["Performance Monitoring"]
        A["Hook Execution Times"]
        B["Error Rates"]
        C["Cost per Task"]
        D["Context Effectiveness"]
  end
 subgraph subGraph1["Analysis Phase"]
        E["Anomaly Detection"]
        F["Pattern Analysis"]
        G["Bottleneck Identification"]
  end
 subgraph subGraph2["Suggestion Generation"]
        H["Claude Analysis"]
        I["Improvement Proposals"]
        J["Implementation Plans"]
  end
 subgraph subGraph3["Human Review"]
        K["Safety Assessment"]
        L["Impact Analysis"]
        M["Approval Decision"]
  end
 subgraph Implementation["Implementation"]
        N["Code Generation"]
        O["Configuration Updates"]
        P["Hook Modifications"]
  end
 subgraph Validation["Validation"]
        Q["Automated Testing"]
        R["Performance Verification"]
        S["Rollback if Needed"]
  end
    A --> E
    B --> E
    C --> F
    D --> F
    E --> H
    F --> H
    G --> H
    H --> I
    I --> J
    J --> K
    K --> L
    L --> M
    M -- Approved --> N
    M -- Rejected --> T["Archive Suggestion"]
    N --> O
    O --> P
    P --> Q
    Q --> R
    R --> S
    S -- Success --> U["Update Baselines"]
    S -- Failure --> V["Revert Changes"]
    U --> A
    V --> A

```

## 📈 Performance Metrics Dashboard Data Flow

This shows how real-time monitoring data is collected and displayed:

```mermaid
---
config:
  theme: neo-dark
  layout: dagre
---
flowchart TD
 subgraph subGraph0["Metric Sources"]
        A["Hook Execution"]
        B["Database Queries"]
        C["Agent Activities"]
        D["System Resources"]
  end
 subgraph subGraph1["Collection Layer"]
        E["Prometheus Exporters"]
        F["Custom Metrics"]
        G["Log Aggregation"]
  end
 subgraph subGraph2["Storage & Processing"]
        H[("Prometheus TSDB")]
        I["Alerting Rules"]
        J["Grafana Queries"]
  end
 subgraph Visualization["Visualization"]
        K["Real-time Dashboards"]
        L["Alert Notifications"]
        M["Performance Reports"]
  end
 subgraph Actions["Actions"]
        N["Human Operator"]
        O["Automated Responses"]
        P["System Adjustments"]
  end
    A --> E
    B --> F
    C --> G
    D --> E
    E --> H
    F --> H
    G --> H
    H --> I & J & M
    I --> L
    J --> K
    L --> N & O
    K --> N
    M --> N
    N --> P
    O --> P

```

---

These data flow diagrams complement the architectural diagrams by showing the dynamic aspects of the system - how information moves, transforms, and creates feedback loops that enable continuous improvement and learning.
