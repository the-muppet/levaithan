# LevAIthan System Architecture

This document provides visual representations of the LevAIthan system architecture, workflows, and interactions.

## 🔄 Core Agent Interaction Flow

The following sequence diagram shows how an agent interacts with the system through the Agent Coordination Protocol (ACP):

```mermaid
---
config:
  theme: redux-dark-color
---
sequenceDiagram
  participant User as User
  participant Claude as Claude
  participant Orchestrator as Orchestrator
  participant PreHooks as PreHooks
  participant PostHooks as PostHooks
  participant DBs as DBs
  autonumber
  User ->> Claude: "Refactor the authentication logic"
  Claude -->> Orchestrator: Trigger PreToolUse Hooks
  Orchestrator ->> PreHooks: Execute scope-validation.sh
  PreHooks -->> DBs: Check for conflicts, lock resources
  DBs -->> PreHooks: OK
  PreHooks -->> Orchestrator: Validation Passed (Exit 0)
  Orchestrator ->> PreHooks: Execute context-injector.sh
  PreHooks -->> Orchestrator: Context Ready
  Orchestrator -->> Claude: Proceed with Tool Use
  Claude -->> Orchestrator: Trigger PostToolUse Hooks
  Orchestrator ->> PostHooks: Execute cost-monitor.sh
  PostHooks -->> DBs: Log token usage and cost
  Orchestrator ->> PostHooks: Execute pattern-learner.sh
  PostHooks -->> DBs: Analyze and store new code patterns
  Orchestrator -->> User: Task Completed

```

## 🧠 Self-Improvement Evolution Cycle

This diagram illustrates how the system continuously improves itself through analysis and automated code modification:

```mermaid
---
config:
  theme: redux-dark-color
  name: "constant self improvement"
---
sequenceDiagram
  participant Learner as "Pattern Learner"
  participant Logs as Logs
  participant DBs as DBs
  participant ClaudeCLI as "Claude CLI"
  participant Codebase as Codebase
  autonumber
  loop "Nightly or On-Demand"
    Learner ->> Logs: "Read performance data"
    Learner ->> DBs: "Read effectiveness data"
    Learner ->> ClaudeCLI: "Analyze performance data"
    ClaudeCLI -->> Learner: "JSON with suggestions"
    Learner ->> ClaudeCLI: "Generate bash script"
    ClaudeCLI -->> Learner: "Bash script modification"
    Learner ->> Codebase: "Apply modification"
    Learner ->> Codebase: "Update Evolution Roadmap"
  end
```

## 🏗️ Complete System Architecture

This comprehensive diagram shows all major components and their relationships:

```mermaid
---
config:
  theme: neo-dark
  layout: elk
---
flowchart TD

 subgraph UI["User Interaction"]
        B["Claude Engine"]
        A["User/Agent Prompt"]
  end
 subgraph PreHooks["Pre-Tool-Use Hooks"]
        D["scope-validation.sh"]
        E["context-injector.sh"]
        F["duplicate-detector.sh"]
  end
 subgraph PostHooks["Post-Tool-Use Hooks"]
        G["cost-monitor.sh"]
        H["pattern-learner.sh"]
        I["self-improving-pattern-learner.sh"]
  end
 subgraph Tools["Shared Libraries & Tools"]
        J["logging-system.sh"]
        K["Claude CLI"]
        L["External Tools"]
  end
 subgraph HS["Hook System"]
        C["hook-orchestrator.sh"]
        PreHooks
        PostHooks
        Tools
  end
 subgraph Data["Data & State Layer"]
        M["Database: coordination.db"]
        N["Database: patterns.db"]
        O["Database: cost-tracking.db"]
        P["Structured Logs"]
        Q["Configuration"]
  end
    A --> B
    B --> C
    C --> D & E & F & G & H & I & M
    D --> J & M & Q
    E --> J & K & Q
    F --> J & N
    G --> J & O & Q
    H --> J & N
    I --> J & K & P & N & M & D & E & G & H & Q
    J --> P
```

## 🗄️ Polyglot Data Access Layer

The system uses multiple specialized databases, accessed through a unified data access layer:

```mermaid
---
config:
  theme: neo-dark
  layout: dagre
---
flowchart TD
 subgraph Agent["Agent Interaction"]
        B["Orchestrator"]
        A["Agent via ACP"]
  end
 subgraph Hooks["Hooks & Workflows"]
        C["Workflows"]
        D["Atomic Hooks"]
  end
 subgraph DAL["Data Access Layer"]
        E["lib/data-access.sh"]
  end
 subgraph Polyglot["Polyglot Persistence Layer"]
        F["PostgreSQL<br>Relational DB"]
        G["HelixDB<br>Graph DB"]
        H["Prometheus<br>Time-Series DB"]
        I["Weaviate<br>Vector DB"]
        J["Elasticsearch<br>Search/Log Index"]
  end
    A --> B
    B --> C
    C --> D
    D --> E
    E --> F & G & H & I & J

```

## 👥 Human-AI Centaur Governance Model

This diagram shows the layered governance structure with human sovereignty:

```mermaid
---
config:
  theme: neo-dark
  layout: elk
---
flowchart TB
 subgraph UILayer["User Interface Layer"]
        UI["system-cli.sh"]
        Dash["Web Dashboard"]
  end
 subgraph Gov["Governance Layers"]
        L1["Cost"]
        L2["Performance"]
        L3["Security"]
  end
 subgraph Cap["Primary Capabilities"]
        P1["Coordination"]
        P2["Knowledge Acquisition"]
        P3["Evolution"]
  end
 subgraph Core["The Core"]
        A["Agent via ACP"]
  end
 subgraph DataLayer["Data Layer"]
        DBs["Polyglot Persistence"]
  end
    H["Human Operator"] --> UI & Dash
    UI --> L1 & L2 & L3 & P1 & P2 & P3
    Dash --> L1 & L2 & L3 & P1 & P2 & P3
    A --> P1 & P2 & P3
    P1 --> L1 & L2 & L3 & DBs
    P2 --> L1 & L2 & L3 & DBs
    P3 --> L1 & L2 & L3 & DBs
    L1 --> DBs
    L2 --> DBs
    L3 --> DBs

```

## 📋 Agent Coordination Protocol (ACP) State Machine

This state machine shows the lifecycle of an agent session:

```mermaid
stateDiagram-v2
    [*] --> TaskDeclaration
    TaskDeclaration --> PreToolUseValidation : declare_task()
    
    PreToolUseValidation --> EthicsCheck
    EthicsCheck --> BudgetCheck
    BudgetCheck --> SecurityCheck
    SecurityCheck --> ResourceLocking
    ResourceLocking --> ContextInjection
    ContextInjection --> SessionApproved
    
    SessionApproved --> AgentExecution : accept_context()
    
    AgentExecution --> ActivityReporting : report_activity()
    ActivityReporting --> AgentExecution
    AgentExecution --> TaskCompletion : report_completion()
    
    TaskCompletion --> PostToolUseProcessing
    PostToolUseProcessing --> CostCalculation
    CostCalculation --> KnowledgeExtraction
    KnowledgeExtraction --> ContextEffectiveness
    ContextEffectiveness --> ResourceCleanup
    ResourceCleanup --> SessionClosed
    
    SessionClosed --> [*]
    
    %% Error paths
    EthicsCheck --> TaskBlocked : Ethics Violation
    BudgetCheck --> TaskBlocked : Budget Exceeded
    SecurityCheck --> TaskBlocked : Security Violation
    ResourceLocking --> TaskBlocked : Resource Conflict
    TaskBlocked --> [*]
```

## 🔄 Hook Execution Flow

This flowchart shows how atomic hooks are composed into workflows:

```mermaid
flowchart TD
    %% Main Entry Point
    Start([Agent ACP Message]) --> Parse{Parse Event Type}
    
    %% Route to Workflows
    Parse -->|task_declaration| PreFlow[Pre-Tool-Use Workflow]
    Parse -->|completion_report| PostFlow[Post-Tool-Use Workflow]
    Parse -->|delegation_request| DelegFlow[Delegation Workflow]
    Parse -->|human_correction| CorrFlow[Human Correction Workflow]
    
    %% Pre-Tool-Use Workflow
    PreFlow --> Ethics[Check Ethics]
    Ethics -->|Pass| Budget[Check Budget]
    Budget -->|Pass| Security[Check Permissions]
    Security -->|Pass| CreateSess[Create Session]
    CreateSess --> AcquireLock[Acquire Locks]
    AcquireLock --> FindCtx[Find Context]
    FindCtx --> InjectCtx[Inject Context]
    InjectCtx --> ApproveSess[Approve Session]
    ApproveSess --> Success([Agent Proceeds])
    
    %% Post-Tool-Use Workflow
    PostFlow --> CalcCost[Calculate Cost]
    CalcCost --> ExtractKnow[Extract Knowledge]
    ExtractKnow --> UpdateEff[Update Effectiveness]
    UpdateEff --> ReleaseLock[Release Locks]
    ReleaseLock --> CloseSess[Close Session]
    CloseSess --> Complete([Task Complete])
    
    %% Delegation Workflow
    DelegFlow --> LogStart[Log Workflow Start]
    LogStart --> GetTask[Get Task Details from Redis]
    GetTask --> ExtractEnv[Extract Envelope Data]
    ExtractEnv --> LogDeleg[Log Delegation Event]
    LogDeleg --> StartIter[Start Sub-task Iteration]
    StartIter --> CheckMore{More Sub-tasks?}
    
    CheckMore -->|Yes| ReadSubtask[Read Next Sub-task]
    ReadSubtask --> StoreSubtask[Store in Redis State]
    StoreSubtask --> LogSubStart[Log Sub-task Start]
    LogSubStart --> ExecHook[Execute coord-create-subtask.sh]
    ExecHook --> SubComplete[Sub-task Complete]
    SubComplete --> CheckMore
    
    CheckMore -->|No| AllDone[All Sub-tasks Processed]
    AllDone --> UpdateParent[Update Parent Task Status]
    UpdateParent --> UpdateSess[Update Session Status]
    UpdateSess --> ReleaseAll[Release All Locks]
    ReleaseAll --> LogComplete[Log Completion]
    LogComplete --> DelegSuccess([Delegation Complete])
    
    %% Human Correction Workflow
    CorrFlow --> GetFeedback[Get Feedback Details]
    GetFeedback --> ValidFeed{Valid Feedback?}
    
    ValidFeed -->|No| LogErr[Log Critical Error]
    LogErr --> CorrFail([Correction Failed])
    
    ValidFeed -->|Yes| StoreFeed[Store Feedback JSON]
    StoreFeed --> LogReason[Log Correction Reason]
    LogReason --> GenFix[Generate Fix from Feedback]
    GenFix --> CaptureSugg[Capture Suggestion]
    CaptureSugg --> StoreSugg[Store Suggestion JSON]
    StoreSugg --> ImplFix[Implement Fix]
    ImplFix --> UpdateFeedStat[Update Feedback Status]
    UpdateFeedStat --> LogSucc[Log Success]
    LogSucc --> CorrSuccess([Correction Complete])
    
    %% Error Handling for Pre-Workflow
    Ethics -->|Fail| BlockTask[Task Blocked]
    Budget -->|Fail| BlockTask
    Security -->|Fail| BlockTask
    AcquireLock -->|Fail| BlockTask
    BlockTask --> Emergency[Emergency Cleanup]
    Emergency --> Failed([Task Failed])
    
    %% Error Handling for Delegation
    ExecHook -->|Fail| DelegErr[Delegation Error]
    DelegErr --> DelegCleanup[Cleanup Partial Delegation]
    DelegCleanup --> DelegFail([Delegation Failed])
    
    %% Styling
    classDef successNode fill:#4CAF50,color:#fff,stroke:#2E7D32
    classDef errorNode fill:#f44336,color:#fff,stroke:#c62828
    classDef processNode fill:#2196F3,color:#fff,stroke:#1565C0
    classDef decisionNode fill:#FF9800,color:#fff,stroke:#E65100
    classDef workflowNode fill:#9C27B0,color:#fff,stroke:#6A1B9A
    
    class Success,Complete,DelegSuccess,CorrSuccess successNode
    class Failed,CorrFail,DelegFail,BlockTask errorNode
    class Parse,CheckMore,ValidFeed decisionNode
    class PreFlow,PostFlow,DelegFlow,CorrFlow workflowNode
```

## 🌐 Multi-Agent Delegation Graph

This shows how complex tasks can be broken down and delegated across multiple agents:

```mermaid
---
config:
  layout: dagre
---
flowchart TB
    User["Human User"] --> Task1["Build E-commerce Site"]
    Task1 --> Agent1["Project Manager Agent"]
    Agent1 --> SubTask1["Backend API Development"] & SubTask2["Frontend Development"] & SubTask3["Database Design"] & SubTask4["DevOps Setup"]
    SubTask1 --> Agent2["Backend Specialist"]
    SubTask2 --> Agent3["Frontend Specialist"]
    SubTask3 --> Agent4["Database Specialist"]
    SubTask4 --> Agent5["DevOps Specialist"]
    Agent2 --> API1["User Authentication"] & API2["Product Catalog"] & API3["Order Processing"]
    Agent3 --> UI1["Login Component"] & UI2["Product Display"] & UI3["Shopping Cart"]
    SubTask3 -- Dependencies --> Agent2
    SubTask1 -- API Contract --> Agent3
    SubTask4 -- Deployment Config --> Agent2
    SubTask4 -- Build Pipeline --> Agent3
    style User fill:#FFEB3B,color:#000
    style Agent1 fill:#2196F3,color:#fff
    style Agent2 fill:#4CAF50,color:#fff
    style Agent3 fill:#FF9800,color:#fff
    style Agent4 fill:#9C27B0,color:#fff
    style Agent5 fill:#F44336,color:#fff

```

## 📊 System Evolution Timeline

This timeline shows how the system improves over time:

```mermaid
gantt
    title System Evolution & Learning Timeline
    dateFormat  YYYY-MM-DD
    section Foundation
    Infrastructure Setup     :done, setup, 2024-01-01, 1w
    Basic Hooks Implementation :done, hooks, after setup, 2w
    Agent Protocol Definition :done, acp, after setup, 1w
    
    section Learning Phase
    Initial Knowledge Accumulation :active, learning, 2024-02-01, 4w
    Pattern Recognition Development :patterns, after learning, 3w
    Context Optimization :context, after patterns, 2w
    
    section Evolution Phase
    Self-Improvement Cycle 1 :evolution1, after context, 1w
    Hook Optimization :optimize, after evolution1, 2w
    Performance Tuning :perf, after optimize, 1w
    Self-Improvement Cycle 2 :evolution2, after perf, 1w
    
    section Advanced Features
    Multi-Agent Coordination :multi, 2024-04-01, 3w
    Advanced Delegation :delegate, after multi, 2w
    Predictive Resource Management :predict, after delegate, 2w
    
    section Maturity
    Full Autonomy Achievement :autonomous, 2024-06-01, ongoing
```

---

## 📋 Diagram Index

| Diagram | Purpose | Section |
|---------|---------|---------|
| **Core Agent Interaction Flow** | Shows basic task lifecycle | Workflow Understanding |
| **Self-Improvement Evolution Cycle** | Illustrates system learning | Evolution Engine |
| **Complete System Architecture** | Overview of all components | System Design |
| **Polyglot Data Access Layer** | Database abstraction | Data Architecture |
| **Human-AI Centaur Governance** | Sovereignty and control | Governance Model |
| **ACP State Machine** | Agent session lifecycle | Protocol Design |
| **Hook Execution Flow** | Workflow composition | Implementation |
| **Multi-Agent Delegation** | Complex task breakdown | Coordination |
| **System Evolution Timeline** | Development roadmap | Project Planning |
| **Security & Governance Architecture** | Multi-layered protection | Security Design |

These diagrams provide comprehensive visual documentation for the LevAIthan system, making it easier for developers, operators, and stakeholders to understand the architecture and workflows.
