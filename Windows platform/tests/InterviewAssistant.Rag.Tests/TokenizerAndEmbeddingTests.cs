using System.Text.Json;

namespace InterviewAssistant.Rag.Tests;

[Collection("model")]
public sealed class TokenizerAndEmbeddingTests(EmbeddingFixture fixture)
{
    private sealed record GoldenItem(string text, int[] ids, float[] embedding);
    private sealed record Golden(string source, GoldenItem[] items);

    private static Golden Load() => JsonSerializer.Deserialize<Golden>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "TestData", "golden.json")))!;

    [Fact]
    public void Tokenizer_matches_reference_tokenizer_ids()
    {
        var tokenizer = fixture.Service.Tokenizer;
        foreach (var item in Load().items)
            Assert.Equal(item.ids, tokenizer.Encode(item.text));
    }

    [Fact]
    public void Embeddings_match_reference_pipeline_and_are_unit_length()
    {
        var golden = Load().items;
        var vectors = fixture.Service.Embed(golden.Select(item => item.text).ToList());
        for (var index = 0; index < golden.Length; index++)
        {
            var vector = vectors[index];
            Assert.Equal(LocalEmbeddingService.Dimension, vector.Length);
            Assert.InRange(Math.Sqrt(vector.Sum(value => (double)value * value)), 0.999, 1.001);
            // Same model, tokens and pooling as the Python reference: cosine ≈ 1 (int8 kernels may differ slightly).
            Assert.True(VectorMath.Dot(vector, golden[index].embedding) > 0.999, $"cosine too low for '{golden[index].text}'");
        }
    }

    [Fact]
    public void Batched_and_single_embeddings_agree()
    {
        var texts = Load().items.Select(item => item.text).ToList();
        var batched = fixture.Service.Embed(texts);
        for (var index = 0; index < texts.Count; index++)
            Assert.True(VectorMath.Dot(batched[index], fixture.Service.Embed([texts[index]])[0]) > 0.9999);
    }

    [Fact]
    public void Long_input_is_truncated_to_the_model_limit()
    {
        var ids = fixture.Service.Tokenizer.Encode(string.Concat(Enumerable.Repeat("FastAPI monitoring dashboard 监控 ", 400)));
        Assert.Equal(LocalEmbeddingService.MaxSequenceLength, ids.Length);
        Assert.Equal(2, ids[^1]);
        Assert.True(VectorMath.IsUsable(fixture.Service.Embed([string.Concat(Enumerable.Repeat("x ", 2000))])[0]));
    }

    [Fact]
    public void Normalize_handles_zero_and_invalid_vectors()
    {
        Assert.False(VectorMath.IsUsable(VectorMath.Normalize(new float[4])));
        Assert.False(VectorMath.IsUsable(VectorMath.Normalize([1, float.NaN, 0, 0])));
        var unit = VectorMath.Normalize([3, 4]);
        Assert.Equal(0.6f, unit[0], 5);
        Assert.Equal(0.8f, unit[1], 5);
    }
}
