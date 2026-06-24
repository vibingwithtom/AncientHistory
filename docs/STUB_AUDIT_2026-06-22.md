# Stub & Dead-Code Audit — Ancient History

**Date:** 2026-06-22
**Method:** 6 parallel read-only audit agents over the full `MBox Explorer/` tree
(118 Swift files), each classifying files as **STUB / PLACEHOLDER / PARTIAL / OK**
and verifying reachability (wired into UI vs orphaned dead code).

> Reconciliation note: the Conversation subsystem *looked* reachable from its
> backing classes, but `ConversationView` itself is orphaned (only referenced in
> `#Preview`), so that entire cluster is dead in the shipping app.

---

## TL;DR
The fork inherited a large "kitchen-sink" of features, and **most were never wired
into the UI.** The core RAG app (import → index → Ask → Explore → attachments →
export → operations) is **genuinely implemented and working.** Around it sits ~40
files of orphaned or placeholder code. Almost nothing dangerous is *reachable*
today, but several reachable items silently do nothing, and the dead code is a
maintenance / security-review liability.

---

## 1. The real, working app (verified genuine + wired)
- **Pipeline:** `ContentView`, `EmailListView`, `EmailDetailView`, `AskView` (RAG),
  `ExploreView` + Explore engines, `AttachmentsView`, `AnalyticsView`,
  `MboxOperationsView`, `NetworkVisualizationView`, `AISettingsView`.
- **AI core:** `LocalLLM`, `VectorDatabase`, `EndpointLanguageModel`,
  `OpenAICompatibleEngine` (real SSE streaming), `TranscriptChatMapper`.
- **Embeddings:** all five providers do real network/compute (Apple NL, Ollama,
  OpenAI, OpenWebUI, TinyChat).
- **IO:** `ExportEngine` + CSV/JSON/Markdown, `PIIRedactor`, `TextProcessor`,
  `TextHighlighter`, `RecentFilesManager`, `SearchHistoryManager`,
  `WindowStateManager`, `MboxFileOperations`.

---

## 2. Reachable today, but broken/misleading — *fix candidates*

| # | Where | Problem |
|---|-------|---------|
| 1 | **AskView.swift:458** | Clicking a cited **source** does nothing — `selectedSource` is set but read nowhere (`// TODO: Navigate to email`). Headline RAG feature. |
| 2 | **SidebarView.swift:63** | **"Find Duplicates"** button is a no-op — its sheet in `ContentView.swift:241-243` is commented out. (`DuplicatesView` is fully orphaned.) |
| 3 | **ThemeManager.swift:65** | Theme picker offers 8 themes; **AMOLED/Solarized/Nord/Custom all render as plain dark** (collapse to `.darkAqua`). |
| 4 | **MBox_ExplorerApp.swift:60-66** + **KeyboardNavigationModifier.swift:94** | Three dead commands: menu **"Export Filtered"**, **"Export Current Thread"**, and the **`e` shortcut** post notifications no one observes. |
| 5 | **ThreeColumnLayoutView.swift:204** | Attachments-pane **"View"** button has an empty body. |
| 6 | **OpenAIEmbeddingProvider.swift:65** | Reads its API key from a **stale pre-fork `cloud_credentials.json` path** that won't load under the new sandbox → silently "unavailable" even with a valid key. |
| 7 | **MboxFileOperations.swift:261** | mbox writer doesn't escape `From ` lines in bodies → can corrupt merged/split output. Reachable via Merge/Split. |
| 8 | **HypotheticalExplorer** | Explore Mode works, but 2 of its 4 modes (`compareOutcomes`, `traceImplications`) have **no call site** — written, unreachable. |

---

## 3. Orphaned features — real code, **zero UI path** (decide: wire up vs delete)
- **Entire Conversation subsystem:** `ConversationView` (~800 lines) +
  `ConversationManager`, `ConversationDatabase`, `CommitmentTracker`,
  `DecisionArchaeologist`, `RelationshipMapper`, `SentimentAnalyzer`,
  `PatternDetector`, `SmartSuggestions`.
- **Entire `AI/Features/*`:** ActionItem, AttachmentSearcher, EmailForensics,
  MeetingEvent, NaturalLanguageFilter, PersonProfile, SentimentDashboard,
  SimilarEmailFinder, ThreadSummarizer, ThreatDetector, TopicClustering
  (reachable only through the dead `BatchOperationsView` / `RichExporter` island).
- **`Views/Features/*`:** Heatmap, WordCloud, TagsCollections, CommandPalette,
  EmailStatisticsDashboard, EmailDiff, BatchOperations, Timeline.
- **`MultiWindowManager`** + its 4 window views (whole multi-window subsystem,
  no entry point).
- **Services:** ContactExporter, NotificationService, QuickLookPreview,
  MailboxMerger, MultiFormatImporter.
- **AI dupes/dead:** `EmailSearchAgent`, `AutoTagger`, `EmailSummarizer`
  (superseded by `ThreadSummarizer`).
- **M6 anti-hallucination layer:** `CitedAnswer` / `CitationVerifier` /
  `EvalHarness` are well-formed but have **zero call sites** — citation-verified
  answers are never actually produced.

> The "Show in Email" sheets added earlier (TimelineView/Tags/WordCloud) were to
> orphaned views — preemptive fixes.

---

## 4. Latent placeholders (inside orphaned code — only bite if you wire them up)
- **BackgroundIndexer.storeEmail** — empty body; drives full progress UI but
  **stores nothing** (fake "indexing complete").
- **AttachmentSearcher** — builds every attachment with empty `Data()` (the model
  carries no bytes) → always 0 results.
- **EmailForensics / ThreatDetector** — analyze synthetic headers; SPF/DKIM/routing
  always empty / "Not Checked".
- **AutoTagger** — header says "ML-powered"; body is `contains()` keyword matching.
- **MultiFormatImporter.importMSG** — returns garbage for Outlook `.msg` (no OLE
  parsing), yet `.msg` is advertised as supported.
- **ConversationManager.getEmailForCitation** → `return nil`;
  **PatternDetector.detectResponseDelays** → `return []`;
  **SpotlightIntegration** → intentional privacy no-op.

---

## Recommendation
Classic forked scope-sprawl. Cleanest path is a **triage**: keep the RAG core,
**fix the ~8 reachable issues in §2** (small, high-value), and **delete the
orphaned §3/§4 code** to shrink the surface (less to maintain, fewer false leads
in security reviews, smaller binary). Wiring up an orphaned feature should be a
deliberate per-feature decision, not a default.
