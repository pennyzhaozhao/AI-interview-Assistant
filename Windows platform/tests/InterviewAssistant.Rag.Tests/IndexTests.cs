namespace InterviewAssistant.Rag.Tests;

[Collection("model")]
public sealed class IndexTests
{
    private static async Task<KnowledgeIndexCoordinator> Synced(TempDirectory temp, IReadOnlyList<RagDocument> documents, bool withModel = true)
    {
        var coordinator = new KnowledgeIndexCoordinator(temp.Path, withModel && ModelLocator.Directory is { } dir ? [dir] : []);
        coordinator.RequestSync(documents);
        await coordinator.WhenIdleAsync();
        return coordinator;
    }

    [Fact]
    public async Task Import_creates_chunks_and_embeddings()
    {
        ModelLocator.Require();
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, TestKnowledge.All);
        Assert.Equal(RagIndexState.Ready, coordinator.Status.State);
        Assert.Equal(TestKnowledge.All.Count, coordinator.Status.IndexedEntries);
        Assert.Equal(0, coordinator.Status.PendingEmbeddings);
        Assert.True(coordinator.Status.TotalChunks > TestKnowledge.All.Count);
    }

    [Fact]
    public async Task Update_reindexes_only_the_changed_entry()
    {
        ModelLocator.Require();
        using var temp = new TempDirectory();
        var documents = TestKnowledge.All.ToList();
        using (var coordinator = await Synced(temp, documents)) { }
        using var index = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        var before = index.Chunks.ToDictionary(item => item.Chunk.ChunkId, item => item.Chunk.EntryId);
        index.Dispose();

        documents[1] = TestKnowledge.Dashboard with { Content = TestKnowledge.Dashboard.Content + "\nWe later added Grafana alerts for SLO burn rates." };
        using (var updated = await Synced(temp, documents)) { }
        var reloaded = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        var now = reloaded.Chunks;
        reloaded.Dispose();
        // Unchanged entries keep exactly the same chunk IDs; the edited entry has new ones.
        var unchanged = before.Where(pair => pair.Value != TestKnowledge.DashboardId).Select(pair => pair.Key).ToHashSet();
        Assert.True(unchanged.IsSubsetOf(now.Select(item => item.Chunk.ChunkId)));
        Assert.Contains(now, item => item.Chunk.EntryId == TestKnowledge.DashboardId && item.Chunk.Text.Contains("Grafana"));
        Assert.DoesNotContain(now, item => before.ContainsKey(item.Chunk.ChunkId) && item.Chunk.EntryId == TestKnowledge.DashboardId);
        Assert.All(now, item => Assert.NotNull(item.Vector));
    }

    [Fact]
    public async Task Delete_removes_entry_and_leaves_no_orphans()
    {
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, TestKnowledge.All, withModel: false);
        coordinator.RequestSync(TestKnowledge.All.Where(document => document.EntryId != TestKnowledge.TravelId).ToList());
        await coordinator.WhenIdleAsync();
        coordinator.Dispose();
        using var index = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        Assert.DoesNotContain(index.Chunks, item => item.Chunk.EntryId == TestKnowledge.TravelId);
        Assert.False(index.Entries.ContainsKey(TestKnowledge.TravelId));
        Assert.Equal(index.Entries.Keys.ToHashSet(), index.Chunks.Select(item => item.Chunk.EntryId).ToHashSet());
    }

    [Fact]
    public async Task Deleting_a_knowledge_base_removes_its_entries()
    {
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, TestKnowledge.All, withModel: false);
        coordinator.RequestSync(TestKnowledge.All.Where(document => document.KnowledgeBaseId != TestKnowledge.ProductKb).ToList());
        await coordinator.WhenIdleAsync();
        var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare("fintech sign-up conversion A/B test", [], "", []),
            new HashSet<Guid> { TestKnowledge.ProductKb }, null);
        Assert.Empty(result.Chunks);
    }

    [Fact]
    public async Task Disabled_entries_are_never_retrieved()
    {
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, TestKnowledge.All, withModel: false);
        var enabled = TestKnowledge.EnabledIds(TestKnowledge.All).Where(id => id != TestKnowledge.TravelId).ToHashSet();
        var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare("PHP Laravel MySQL Stripe webhook", [], "", []), TestKnowledge.EngineerOnly, enabled);
        Assert.DoesNotContain(result.Chunks, chunk => chunk.Chunk.EntryId == TestKnowledge.TravelId);
    }

    [Fact]
    public async Task Rebuild_restart_and_reload_keep_vectors()
    {
        ModelLocator.Require();
        using var temp = new TempDirectory();
        using (var coordinator = await Synced(temp, TestKnowledge.All))
        {
            coordinator.RequestRebuild(TestKnowledge.All);
            await coordinator.WhenIdleAsync();
            Assert.Equal(RagIndexState.Ready, coordinator.Status.State);
        }
        using var index = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        Assert.Equal(TestKnowledge.All.Count, index.Entries.Count);
        Assert.Equal(0, index.ChunksWithoutEmbedding);
        // A restart with unchanged data does no work.
        index.Dispose();
        using var restarted = await Synced(temp, TestKnowledge.All);
        Assert.Equal(0, restarted.Status.PendingEmbeddings);
    }

    [Fact]
    public void Corrupted_index_file_is_recreated()
    {
        using var temp = new TempDirectory();
        File.WriteAllText(Path.Combine(temp.Path, LocalVectorIndex.FileName), "this is not a database");
        using var index = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        Assert.True(index.WasRecreated);
        Assert.Empty(index.Chunks);
        index.ReplaceEntry(TestKnowledge.EngineerKb, TestKnowledge.TravelId, "h", KnowledgeChunker.Chunk(TestKnowledge.Travel), LocalEmbeddingService.ModelVersion);
        Assert.NotEmpty(index.Chunks);
    }

    [Fact]
    public void Model_version_change_drops_old_vectors_but_keeps_chunks()
    {
        using var temp = new TempDirectory();
        var chunks = KnowledgeChunker.Chunk(TestKnowledge.Travel);
        using (var index = LocalVectorIndex.Open(temp.Path, "old-model"))
        {
            index.ReplaceEntry(TestKnowledge.EngineerKb, TestKnowledge.TravelId, "h", chunks, "old-model");
            index.StoreEmbeddings(chunks.Select(chunk => (chunk.ChunkId, VectorMath.Normalize(Enumerable.Repeat(1f, LocalEmbeddingService.Dimension).ToArray()))).ToList(), "old-model");
            Assert.Equal(0, index.ChunksWithoutEmbedding);
        }
        using var reopened = LocalVectorIndex.Open(temp.Path, "new-model");
        Assert.Equal(chunks.Count, reopened.Chunks.Count);
        Assert.Equal(chunks.Count, reopened.ChunksWithoutEmbedding);
    }

    [Fact]
    public void Wrong_dimension_vectors_are_ignored()
    {
        using var temp = new TempDirectory();
        var chunks = KnowledgeChunker.Chunk(TestKnowledge.Travel);
        using (var index = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion))
        {
            index.ReplaceEntry(TestKnowledge.EngineerKb, TestKnowledge.TravelId, "h", chunks, LocalEmbeddingService.ModelVersion);
            index.StoreEmbeddings([(chunks[0].ChunkId, new float[] { 1, 0, 0 })], LocalEmbeddingService.ModelVersion);
        }
        using var reopened = LocalVectorIndex.Open(temp.Path, LocalEmbeddingService.ModelVersion);
        Assert.All(reopened.Chunks, item => Assert.Null(item.Vector));
    }

    [Fact]
    public async Task Cancelled_indexing_resumes_on_next_sync()
    {
        ModelLocator.Require();
        using var temp = new TempDirectory();
        var coordinator = new KnowledgeIndexCoordinator(temp.Path, [ModelLocator.Directory!]);
        coordinator.RequestSync(TestKnowledge.All);
        coordinator.Dispose();   // interrupt (as on app shutdown)
        using var resumed = await Synced(temp, TestKnowledge.All);
        Assert.Equal(0, resumed.Status.PendingEmbeddings);
        Assert.Equal(TestKnowledge.All.Count, resumed.Status.IndexedEntries);
    }

    [Fact]
    public async Task Without_model_the_index_works_with_keyword_search()
    {
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, TestKnowledge.All, withModel: false);
        Assert.Equal(RagIndexState.KeywordOnly, coordinator.Status.State);
        var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare("Tell me about your FastAPI project", [], "", []), TestKnowledge.EngineerOnly, null);
        Assert.Equal(RetrievalMode.LexicalOnly, result.Mode);
        Assert.Contains(result.Chunks, chunk => chunk.Chunk.EntryId == TestKnowledge.DashboardId);
    }

    [Fact]
    public async Task Empty_knowledge_base_returns_no_passages()
    {
        using var temp = new TempDirectory();
        using var coordinator = await Synced(temp, [], withModel: false);
        var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare("anything", [], "", []), TestKnowledge.EngineerOnly, null);
        Assert.Empty(result.Chunks);
    }
}
