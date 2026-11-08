using Microsoft.ML.OnnxRuntime;

namespace InterviewAssistant.Rag;

/// <summary>
/// Local sentence embeddings with ONNX Runtime (CPU): intfloat/multilingual-e5-small, int8-quantized ONNX export
/// (Xenova), 384 dimensions, MIT license. Mean pooling over the attention mask followed by L2 normalization,
/// as specified by the model card, so dot product equals cosine similarity.
/// Nothing leaves the machine: no network access is made by this class.
/// </summary>
public sealed class LocalEmbeddingService : IDisposable
{
    /// <summary>Changing the model, its export, pooling or the tokenizer must change this string: stored vectors are then re-embedded.</summary>
    public const string ModelVersion = "multilingual-e5-small/xenova-int8/mean-l2/v1";
    public const int Dimension = 384;
    public const int MaxSequenceLength = 512;
    public const string ModelFileName = "model_quantized.onnx";
    public const string TokenizerFileName = "tokenizer.json";

    private readonly XlmRobertaTokenizer _tokenizer;
    private readonly InferenceSession _session;
    private readonly bool _needsTokenTypes;
    private readonly string _outputName;

    private LocalEmbeddingService(XlmRobertaTokenizer tokenizer, InferenceSession session)
    {
        _tokenizer = tokenizer;
        _session = session;
        _needsTokenTypes = session.InputMetadata.ContainsKey("token_type_ids");
        _outputName = session.OutputMetadata.ContainsKey("last_hidden_state") ? "last_hidden_state" : session.OutputMetadata.Keys.First();
        var dimension = session.OutputMetadata[_outputName].Dimensions.LastOrDefault();
        if (dimension > 0 && dimension != Dimension) throw new InvalidDataException($"Embedding model outputs {dimension} dimensions, expected {Dimension}.");
    }

    public XlmRobertaTokenizer Tokenizer => _tokenizer;

    /// <summary>True when the model and tokenizer files exist in <paramref name="modelDirectory"/>.</summary>
    public static bool FilesExist(string? modelDirectory) =>
        !string.IsNullOrWhiteSpace(modelDirectory)
        && File.Exists(Path.Combine(modelDirectory, ModelFileName))
        && File.Exists(Path.Combine(modelDirectory, TokenizerFileName));

    public static LocalEmbeddingService Load(string modelDirectory, int? threads = null)
    {
        var tokenizer = XlmRobertaTokenizer.Load(Path.Combine(modelDirectory, TokenizerFileName));
        var options = new SessionOptions
        {
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
            IntraOpNumThreads = threads ?? Math.Clamp(Environment.ProcessorCount / 2, 1, 4),
            InterOpNumThreads = 1,
            LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR
        };
        var session = new InferenceSession(Path.Combine(modelDirectory, ModelFileName), options);
        return new LocalEmbeddingService(tokenizer, session);
    }

    /// <summary>Embeds an interview question ("query: " prefix, as e5 expects).</summary>
    public float[] EmbedQuery(string query) => Embed(["query: " + query])[0];

    /// <summary>Embeds passages; <paramref name="texts"/> must already carry the "passage: " prefix (see RagChunk.EmbeddingText).</summary>
    public float[][] Embed(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
    {
        // One text per run: the int8 model quantizes activations dynamically over the whole input tensor, so padding
        // other texts into a batch would change each vector slightly. Single runs make every vector reproducible
        // (the same passage always gets the same vector, at index time and at query time).
        var result = new float[texts.Count][];
        for (var index = 0; index < texts.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            result[index] = RunBatch([_tokenizer.Encode(texts[index], MaxSequenceLength)])[0];
        }
        return result;
    }

    private float[][] RunBatch(List<int[]> batch)
    {
        var rows = batch.Count;
        var length = batch.Max(ids => ids.Length);
        var inputIds = new long[rows * length];
        var mask = new long[rows * length];
        var types = new long[rows * length];
        for (var row = 0; row < rows; row++)
        {
            var ids = batch[row];
            for (var column = 0; column < length; column++)
            {
                var index = row * length + column;
                if (column < ids.Length) { inputIds[index] = ids[column]; mask[index] = 1; }
                else inputIds[index] = XlmRobertaTokenizer.PadId;
            }
        }
        long[] shape = [rows, length];
        using var idsValue = OrtValue.CreateTensorValueFromMemory(inputIds, shape);
        using var maskValue = OrtValue.CreateTensorValueFromMemory(mask, shape);
        using var typesValue = OrtValue.CreateTensorValueFromMemory(types, shape);
        var names = new List<string> { "input_ids", "attention_mask" };
        var values = new List<OrtValue> { idsValue, maskValue };
        if (_needsTokenTypes) { names.Add("token_type_ids"); values.Add(typesValue); }
        using var runOptions = new RunOptions();
        using var outputs = _session.Run(runOptions, names, values, [_outputName]);
        var hidden = outputs[0].GetTensorDataAsSpan<float>();
        var vectors = new float[rows][];
        for (var row = 0; row < rows; row++)
        {
            var vector = new float[Dimension];
            var tokens = 0;
            for (var column = 0; column < length; column++)
            {
                if (mask[row * length + column] == 0) continue;
                tokens++;
                var baseIndex = (row * length + column) * Dimension;
                for (var d = 0; d < Dimension; d++) vector[d] += hidden[baseIndex + d];
            }
            if (tokens > 0) for (var d = 0; d < Dimension; d++) vector[d] /= tokens;
            vectors[row] = VectorMath.Normalize(vector);
        }
        return vectors;
    }

    public void Dispose() => _session.Dispose();
}

public static class VectorMath
{
    /// <summary>e = f(x) / ‖f(x)‖₂. Zero, NaN or infinite vectors become all-zero (and are never matched).</summary>
    public static float[] Normalize(float[] vector)
    {
        double sum = 0;
        foreach (var value in vector)
        {
            if (!float.IsFinite(value)) { Array.Clear(vector); return vector; }
            sum += (double)value * value;
        }
        var norm = Math.Sqrt(sum);
        if (norm < 1e-12 || !double.IsFinite(norm)) { Array.Clear(vector); return vector; }
        for (var index = 0; index < vector.Length; index++) vector[index] = (float)(vector[index] / norm);
        return vector;
    }

    public static bool IsUsable(float[]? vector)
    {
        if (vector is null || vector.Length == 0) return false;
        foreach (var value in vector) if (value != 0) return true;
        return false;
    }

    public static double Dot(ReadOnlySpan<float> left, ReadOnlySpan<float> right)
    {
        var length = Math.Min(left.Length, right.Length);
        return System.Numerics.Tensors.TensorPrimitives.Dot(left[..length], right[..length]);
    }

    public static byte[] ToBytes(float[] vector)
    {
        var bytes = new byte[vector.Length * sizeof(float)];
        Buffer.BlockCopy(vector, 0, bytes, 0, bytes.Length);
        if (!BitConverter.IsLittleEndian) ReverseEach(bytes);
        return bytes;
    }

    public static float[]? FromBytes(byte[]? bytes, int expectedDimension)
    {
        if (bytes is null || bytes.Length != expectedDimension * sizeof(float)) return null;
        var copy = (byte[])bytes.Clone();
        if (!BitConverter.IsLittleEndian) ReverseEach(copy);
        var vector = new float[expectedDimension];
        Buffer.BlockCopy(copy, 0, vector, 0, copy.Length);
        return vector;
    }

    private static void ReverseEach(byte[] bytes)
    {
        for (var index = 0; index < bytes.Length; index += 4) Array.Reverse(bytes, index, 4);
    }
}
