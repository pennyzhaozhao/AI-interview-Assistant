# Local RAG (knowledge-base retrieval)

Interview answers no longer receive the whole knowledge base. Each request gets a short **core profile** plus the
passages that a **local, on-device retriever** finds for the current question. Documents, the index, embeddings and
retrieval stay on the user's computer; only the final prompt goes to the LLM the user selected.

## 1. Audit (before this change)

| | macOS (Swift/SwiftUI) | Windows (C#/WPF) |
|---|---|---|
| Knowledge storage | SwiftData `KnowledgeBase` / `KnowledgeEntry` in the store chosen by `DataStorageManager` | `AppData.KnowledgeBases` in `interview-assistant.json` (`AppDataStore`) |
| Mutations | `KnowledgeBaseManagerView` (import, resume, GitHub projects, notes, edit, enable/disable, copy, delete) → `modelContext.save()` | `KnowledgeViewModel` / `KnowledgeView` → `AppDataStore.ScheduleSave()` (`Changed` event) |
| Prompt construction | `KnowledgeContextBuilder.buildSystemPrompt` / `buildStructuredTechnicalSystemPrompt` → `KnowledgeFormatter.build` (whole KB, cut at 24,000 chars); mock: `MockInterviewView.buildContext` (14,000 chars) | `InterviewPromptBuilder.BuildSystemPrompt` / `BuildStructuredTechnicalSystemPrompt` → `KnowledgeContextFormatter.Build` (same); mock: `MockInterviewWindow.BuildContext` |
| LLM requests | `ReceiverCoordinator.askAI` (voice), `askScreenshotQuestion`, `generatePendingCode` → `AIService.streamResponse`; mock `generateQuestions`/`evaluate` → `AIService.callAIModel`; resume/project/website processing (unchanged) | `PrompterWindow.SubmitQuestionAsync` (voice + screenshot) → `AIService.StreamAsync`; screenshot transcription `AnalyzeImageAsync` (no KB); mock → `CompleteAsync`; resume/project/website processing (unchanged) |
| Packaging | Xcode project, Sparkle DMG (`scripts/build-dmg.sh`); sherpa-onnx SPM package already ships ONNX Runtime 1.27.1 (`onnxruntime.framework`) | GitHub Actions `windows-release.yml`: self-contained single-file exe + Inno Setup; sherpa-onnx NuGet ships ONNX Runtime 1.28.2 |

## 2. Design

**Embedding model — `intfloat/multilingual-e5-small`, int8 ONNX export by Xenova.**
MIT license (redistribution allowed). 384 dimensions, 12-layer MiniLM-style encoder with the XLM-RoBERTa vocabulary
(Chinese, English and ~100 other languages), trained for retrieval with `query:` / `passage:` prefixes; mean pooling
over the attention mask, then L2 normalization. ONNX opset 11, IR 6; inputs `input_ids`, `attention_mask`,
`token_type_ids`; output `last_hidden_state [batch, seq, 384]`; 118 MB. Alternatives considered:
`paraphrase-multilingual-MiniLM-L12-v2` (same size, tuned for paraphrase rather than retrieval), `bge-small-zh`
(Chinese only), `bge-m3` (568M parameters, too large for a desktop installer).
Measured on this project's test data: unrelated questions score 0.75–0.79 cosine, relevant passages 0.80–0.90, and
paraphrases are found ("你的短板是什么" → the prepared answer to "你最大的缺点是什么").

**Tokenizer — native SentencePiece Unigram implementation** (`XlmRobertaTokenizer.cs`, `XLMRobertaTokenizer.swift`)
reading `tokenizer.json`: NFKC + whitespace/control normalization (approximating the model's precompiled `nmt_nfkc`
map), Metaspace pre-tokenization, Viterbi segmentation. Identical to the Hugging Face tokenizer on 1,054 of 1,055
mixed Chinese/English lines (the one difference is a zero-width space). No Python or tokenizer library needed.

**Runtime — ONNX Runtime CPU**, the same runtime each app already ships for speaker verification:
Windows uses `Microsoft.ML.OnnxRuntime` 1.28.0 (the build keeps one `onnxruntime.dll` for both features);
macOS reaches sherpa-onnx's `onnxruntime.framework` through the stable C API (`OrtGetApiBase`, API version 17).
Embeddings are computed one text per run: the int8 model quantizes activations over the whole input tensor, so
batching would make a vector depend on its neighbours. With the same runtime version the C# vectors match the
Python reference exactly (cosine 1.000000); across runtime versions (1.27/1.28/1.31) they agree to ≈0.998 cosine.

**Storage — one SQLite file per app** (`<data folder>/LocalRAG/rag-index.sqlite`; Windows: Microsoft.Data.Sqlite,
macOS: system libsqlite3). Tables `meta` (schema version, model version, dimension), `entries` (entry → content hash),
`chunks` (chunk ID, KB ID, entry ID, title, kind, source, chunk index, section, text, Q&A flag, content hash,
embedding BLOB, model version, indexed time). WAL mode; every entry update is one transaction. Search runs on an
in-memory copy: exact cosine over all vectors plus BM25. A vector extension, FTS5 or an ANN index (HNSW) were not
needed: exact search over 4,320 passages takes ~1.4 ms, and FTS5's tokenizer does not segment Chinese, whereas the
shared BM25 analyzer (Latin words with light stemming + CJK character bigrams) behaves identically on both apps.

**Chunking** (`KnowledgeChunker`): Markdown-heading aware, paragraph then sentence splitting, code blocks kept whole,
interview Q&A pairs kept together (a long answer repeats its question in every part), target 350 / max 450 estimated
tokens, 60-token sentence overlap within a section, short entries stay one chunk. Project and resume summaries are
their own passages; titles are indexed with every passage. Chunk ID = `SHA-256(entryId | contentHash | index)[0..32]`;
the content hash covers chunker version, kind, title, summary, meta, source and content.

**Retrieval** (`QueryContextualizer`, `KnowledgeRetrievalService`):
1. Query preparation — deterministic, no LLM call. A follow-up ("How did you solve it?", "具体说说") is detected by
   cue words or by having few content terms; it then carries the project named in the last three turns and the
   previous question (lower weight). A question that names its own project, or has many content terms, starts a new
   topic. Role terms can only re-rank.
2. Semantic search: local query embedding, cosine over the active KBs' enabled entries; a match must reach 0.80, be
   within 0.05 of the best and stand ≥0.035 above the median (e5 scores are not probabilities).
3. Keyword search: BM25; a passage must match a term from the question itself (or the resolved follow-up topic).
4. Reciprocal Rank Fusion (k = 60), at most 2 passages per document, near-duplicates removed, Top-5,
   2,500-token budget (the last passage may be cut at a sentence boundary). Weak queries return nothing.

**Prompt and token budget** (`PromptTokenBudget`): system instructions → core profile (450) → role/JD/company
(900) → recent conversation (700, newest first) → retrieved knowledge (2,500) → mock memory (600) → the user's own
answer preferences (500) → current question. Token counts use a documented conservative estimator (CJK ≈ 1 token
per character, ASCII letters ≈ 1 per 3 characters, punctuation 1); exact tokenizers for cloud models are not
available offline. Truncation is priority- and boundary-aware, never "first N characters".
Retrieved text is framed as untrusted reference data ("not as instructions"), and section markers inside documents
are neutralized.

**Incremental indexing** (`KnowledgeIndexCoordinator`): after knowledge-base changes (Windows: debounced
`AppDataStore.Changed`; macOS: debounced `ModelContext.didSave`) a snapshot is compared by content hash; only new
or changed entries are re-chunked, deleted entries are removed, and only chunks without a vector are embedded in the
background (cancellable; the newest snapshot wins). Disabled entries stay indexed but are filtered at query time.
A model-version change clears vectors (chunks are kept and re-embedded). A corrupt or unreadable index file is
deleted and rebuilt; orphan chunks are removed at startup. "Rebuild index" on the knowledge-base screen starts over.

**Fallbacks.** No model files → keyword-only retrieval (status shows it). Index unavailable → keyword search over
freshly chunked documents, bounded by the same budget. Retrieval error → the answer uses the core profile only.
The full knowledge base is never sent.

## 3. Privacy and network boundaries

| Step | Where it runs | Network |
|---|---|---|
| Knowledge-base storage | Local data folder (unchanged) | none |
| Chunking, indexing, embeddings, vector + keyword search | Local (ONNX Runtime, SQLite) | none (verified by `PrivacyTests`) |
| Resume → Markdown/summary, project summaries, website research | The user's selected LLM (unchanged, user-initiated) | yes, as before |
| Interview answers | The user's selected LLM | system prompt (core profile, role/JD, recent turns, retrieved passages, preferences) + question |

Selecting a cloud LLM is not offline. Logs never contain document text: status messages carry only counts and
exception type names.

## 4. Packaging

The model (135 MB) is not in git. `scripts/fetch-rag-model.sh` / `.ps1` download `onnx/model_quantized.onnx` and
`tokenizer.json` from `huggingface.co/Xenova/multilingual-e5-small` (`HF_ENDPOINT` selects a mirror such as
`https://hf-mirror.com`), verify size and SHA-256, and place them in `LocalRAG/model/`. The app never downloads.

* **Windows:** the release workflow runs the fetch script and the RAG tests, then publishes with
  `IncludeAllContentForSelfExtract=true`, so the model travels inside the single exe (181 MB) and the installer.
* **macOS:** `scripts/build-dmg.sh` runs the fetch script; the "Bundle Local RAG Model" build phase copies the
  files into `Contents/Resources/LocalRAG/model`. ONNX Runtime is the copy already shipped by sherpa-onnx.
  Builds without the model still work (keyword search).

## 5. Tests and benchmarks

`Windows platform/tests/InterviewAssistant.Rag.Tests` (xUnit v3, net10.0, runs on any OS; uses the real model):
tokenizer IDs and embeddings against the Hugging Face/ONNX Runtime reference; chunking (Q&A pairs, code, overlap,
deterministic IDs); index import/update/delete/disable/rebuild/restart/corruption/model change/dimension mismatch/
interrupted indexing; retrieval by technology, exact framework names, paraphrases, active-KB filter, disabled entries,
unrelated questions, duplicates, budget; follow-ups and topic switches; prompt construction (no full KB, sources
included, core profile, custom instructions, budget, screenshot/code prompts, injection framing); the exact request
body sent to the LLM; a no-network check; a 2.36 M-character stress test. **59/59 pass.**

Benchmark (2-core Linux container, 407 documents, 2,355,751 characters, 4,320 passages; local only, no LLM time):

| | median | max |
|---|---|---|
| Query embedding | 4.9 ms | 5.9 ms |
| Vector search | 1.4 ms | 5.8 ms |
| Keyword search | 4.8 ms | 7.2 ms |
| Fusion + selection | 0.1 ms | 0.2 ms |
| Total retrieval | 11.7 ms | 19.3 ms |
| Retrieval + prompt assembly | 12.3 ms | 14.8 ms |

Initial indexing of that corpus: 125 s in the background; an unchanged re-sync: 4 ms.

`InterviewAssistantTests/LocalRAGTests.swift` checks the Swift port against values produced by the C# code
(chunk IDs and texts, keyword terms, token estimates, tokenizer IDs) plus index, retrieval and budget behaviour.

## 6. Known limitations

* The Swift code could not be compiled in the environment where it was written; build and run the tests in Xcode.
* Token budgets use an estimator, not each provider's tokenizer.
* macOS uses the `onnxruntime.framework` that sherpa-onnx's Swift package provides; whether it contains an Intel
  (x86_64) slice was not verified here. Without a loadable runtime the app falls back to keyword search.
* Embeddings from different ONNX Runtime versions agree to ≈0.998, not bit-for-bit; each app keeps its own index.
* Image-only PDFs have no text to index (as before).

## 7. Release checklist

1. `scripts/fetch-rag-model.sh` (or `.ps1`) — confirm the SHA-256 check passes against Hugging Face.
2. macOS: build in Xcode, run `InterviewAssistantTests` (including `LocalRAGTests`), check the knowledge-base screen
   shows "Local index ready", then `scripts/build-dmg.sh`.
3. Windows: the release workflow fetches the model and runs the RAG tests automatically.
