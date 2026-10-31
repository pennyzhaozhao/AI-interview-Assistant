using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

public sealed class AIService
{
    private readonly HttpClient _httpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(120)
    };

    public async Task<string> CompleteAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        int maxTokens = 900,
        CancellationToken cancellationToken = default)
    {
        Validate(config);
        return config.Provider switch
        {
            AIProvider.Claude => await CompleteClaudeAsync(config, systemPrompt, question, maxTokens, cancellationToken),
            AIProvider.Gemini => await CompleteGeminiAsync(config, systemPrompt, question, maxTokens, cancellationToken),
            _ => await CompleteOpenAICompatibleAsync(config, systemPrompt, question, maxTokens, cancellationToken)
        };
    }

    /// <summary>
    /// Streams the accumulated answer to <paramref name="onUpdate"/>. Providers without a
    /// compatible SSE endpoint still complete normally and publish once, so callers can use one
    /// code path for every provider.
    /// </summary>
    public async Task<string> StreamAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        Action<string> onUpdate,
        int maxTokens = 900,
        CancellationToken cancellationToken = default)
    {
        Validate(config);
        if (config.Provider == AIProvider.Gemini)
        {
            var completed = await CompleteGeminiAsync(config, systemPrompt, question, maxTokens, cancellationToken);
            onUpdate(completed);
            return completed;
        }

        return config.Provider == AIProvider.Claude
            ? await StreamClaudeAsync(config, systemPrompt, question, onUpdate, maxTokens, cancellationToken)
            : await StreamOpenAICompatibleAsync(config, systemPrompt, question, onUpdate, maxTokens, cancellationToken);
    }

    public Task<string> TestConnectionAsync(AIConfig config, CancellationToken cancellationToken = default) =>
        CompleteAsync(config, "Reply briefly and clearly.", "Reply with OK.", 32, cancellationToken);

    public async Task<string> AnalyzeImageAsync(
        AIConfig config,
        string imagePath,
        string instruction,
        CancellationToken cancellationToken = default)
    {
        Validate(config);
        var base64 = Convert.ToBase64String(await File.ReadAllBytesAsync(imagePath, cancellationToken));
        return config.Provider switch
        {
            AIProvider.Claude => await AnalyzeClaudeImageAsync(config, base64, instruction, cancellationToken),
            AIProvider.Gemini => await AnalyzeGeminiImageAsync(config, base64, instruction, cancellationToken),
            _ => await AnalyzeOpenAIImageAsync(config, base64, instruction, cancellationToken)
        };
    }

    private async Task<string> AnalyzeOpenAIImageAsync(AIConfig config, string base64, string instruction, CancellationToken cancellationToken)
    {
        var baseUrl = NormalizeBaseUrl(config.ApiUrl);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{baseUrl}/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", string.IsNullOrWhiteSpace(config.ApiKey) ? "ollama" : config.ApiKey);
        request.Content = JsonContent.Create(new JsonObject
        {
            ["model"] = config.Model,
            ["stream"] = false,
            ["max_tokens"] = 1200,
            ["messages"] = new JsonArray
            {
                new JsonObject
                {
                    ["role"] = "user",
                    ["content"] = new JsonArray
                    {
                        new JsonObject { ["type"] = "text", ["text"] = instruction },
                        new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = $"data:image/png;base64,{base64}" } }
                    }
                }
            }
        });
        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);
        using var document = JsonDocument.Parse(responseBody);
        return RequireText(document.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString());
    }

    private async Task<string> AnalyzeClaudeImageAsync(AIConfig config, string base64, string instruction, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl);
        request.Headers.Add("x-api-key", config.ApiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = JsonContent.Create(new
        {
            model = config.Model,
            max_tokens = 1200,
            messages = new[] { new { role = "user", content = new object[] { new { type = "text", text = instruction }, new { type = "image", source = new { type = "base64", media_type = "image/png", data = base64 } } } } }
        });
        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);
        using var document = JsonDocument.Parse(responseBody);
        return RequireText(document.RootElement.GetProperty("content")[0].GetProperty("text").GetString());
    }

    private async Task<string> AnalyzeGeminiImageAsync(AIConfig config, string base64, string instruction, CancellationToken cancellationToken)
    {
        var baseUrl = config.ApiUrl.Trim().TrimEnd('/');
        var url = $"{baseUrl}/models/{Uri.EscapeDataString(config.Model)}:generateContent?key={Uri.EscapeDataString(config.ApiKey)}";
        var body = new { contents = new[] { new { parts = new object[] { new { text = instruction }, new { inlineData = new { mimeType = "image/png", data = base64 } } } } } };
        using var response = await _httpClient.PostAsJsonAsync(url, body, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);
        using var document = JsonDocument.Parse(responseBody);
        return RequireText(document.RootElement.GetProperty("candidates")[0].GetProperty("content").GetProperty("parts")[0].GetProperty("text").GetString());
    }

    private async Task<string> CompleteOpenAICompatibleAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        var baseUrl = NormalizeBaseUrl(config.ApiUrl);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{baseUrl}/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", string.IsNullOrWhiteSpace(config.ApiKey) ? "ollama" : config.ApiKey);

        var body = new JsonObject
        {
            ["model"] = config.Model,
            ["stream"] = false,
            ["max_tokens"] = maxTokens,
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = systemPrompt },
                new JsonObject { ["role"] = "user", ["content"] = question }
            }
        };
        if (config.Provider == AIProvider.DeepSeek)
        {
            body["thinking"] = new JsonObject { ["type"] = "disabled" };
        }

        request.Content = JsonContent.Create(body);
        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);

        using var document = JsonDocument.Parse(responseBody);
        var text = document.RootElement
            .GetProperty("choices")[0]
            .GetProperty("message")
            .GetProperty("content")
            .GetString();
        return RequireText(text);
    }

    private async Task<string> StreamOpenAICompatibleAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        Action<string> onUpdate,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        var baseUrl = NormalizeBaseUrl(config.ApiUrl);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{baseUrl}/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", string.IsNullOrWhiteSpace(config.ApiKey) ? "ollama" : config.ApiKey);
        var body = new JsonObject
        {
            ["model"] = config.Model,
            ["stream"] = true,
            ["max_tokens"] = maxTokens,
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = systemPrompt },
                new JsonObject { ["role"] = "user", ["content"] = question }
            }
        };
        if (config.Provider == AIProvider.DeepSeek) body["thinking"] = new JsonObject { ["type"] = "disabled" };
        request.Content = JsonContent.Create(body);

        using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var error = await response.Content.ReadAsStringAsync(cancellationToken);
            EnsureSuccess(response, error);
        }
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream);
        var result = new StringBuilder();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) break;
            if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) continue;
            var data = line[5..].Trim();
            if (data == "[DONE]") break;
            try
            {
                using var json = JsonDocument.Parse(data);
                var choice = json.RootElement.GetProperty("choices")[0];
                if (!choice.TryGetProperty("delta", out var delta) ||
                    !delta.TryGetProperty("content", out var content) ||
                    content.ValueKind != JsonValueKind.String) continue;
                var token = content.GetString();
                if (string.IsNullOrEmpty(token)) continue;
                result.Append(token);
                onUpdate(result.ToString());
            }
            catch (JsonException) { }
        }
        return RequireText(result.ToString());
    }

    private async Task<string> CompleteClaudeAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl);
        request.Headers.Add("x-api-key", config.ApiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = JsonContent.Create(new
        {
            model = config.Model,
            max_tokens = maxTokens,
            system = systemPrompt,
            messages = new[] { new { role = "user", content = question } }
        });

        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);

        using var document = JsonDocument.Parse(responseBody);
        var text = document.RootElement.GetProperty("content")[0].GetProperty("text").GetString();
        return RequireText(text);
    }

    private async Task<string> StreamClaudeAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        Action<string> onUpdate,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl);
        request.Headers.Add("x-api-key", config.ApiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = JsonContent.Create(new
        {
            model = config.Model,
            max_tokens = maxTokens,
            stream = true,
            system = systemPrompt,
            messages = new[] { new { role = "user", content = question } }
        });
        using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var error = await response.Content.ReadAsStringAsync(cancellationToken);
            EnsureSuccess(response, error);
        }
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream);
        var result = new StringBuilder();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) break;
            if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                using var json = JsonDocument.Parse(line[5..].Trim());
                var root = json.RootElement;
                if (!root.TryGetProperty("type", out var type) || type.GetString() != "content_block_delta" ||
                    !root.TryGetProperty("delta", out var delta) || !delta.TryGetProperty("text", out var text) ||
                    text.ValueKind != JsonValueKind.String) continue;
                var token = text.GetString();
                if (string.IsNullOrEmpty(token)) continue;
                result.Append(token);
                onUpdate(result.ToString());
            }
            catch (JsonException) { }
        }
        return RequireText(result.ToString());
    }

    private async Task<string> CompleteGeminiAsync(
        AIConfig config,
        string systemPrompt,
        string question,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        var baseUrl = config.ApiUrl.Trim().TrimEnd('/');
        var url = $"{baseUrl}/models/{Uri.EscapeDataString(config.Model)}:generateContent?key={Uri.EscapeDataString(config.ApiKey)}";
        var body = new
        {
            systemInstruction = new { parts = new[] { new { text = systemPrompt } } },
            contents = new[] { new { role = "user", parts = new[] { new { text = question } } } },
            generationConfig = new { maxOutputTokens = maxTokens }
        };

        using var response = await _httpClient.PostAsJsonAsync(url, body, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        EnsureSuccess(response, responseBody);

        using var document = JsonDocument.Parse(responseBody);
        var text = document.RootElement
            .GetProperty("candidates")[0]
            .GetProperty("content")
            .GetProperty("parts")[0]
            .GetProperty("text")
            .GetString();
        return RequireText(text);
    }

    private static string NormalizeBaseUrl(string value)
    {
        var result = value.Trim().TrimEnd('/');
        foreach (var suffix in new[] { "/chat/completions", "/responses", "/messages" })
        {
            if (result.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                result = result[..^suffix.Length];
                break;
            }
        }
        return result;
    }

    private static void Validate(AIConfig config)
    {
        if (!Uri.TryCreate(config.ApiUrl, UriKind.Absolute, out _))
        {
            throw new InvalidOperationException("The API URL is empty or invalid.");
        }
        if (string.IsNullOrWhiteSpace(config.Model))
        {
            throw new InvalidOperationException("Choose an AI model first.");
        }
        if (ProviderCatalog.Get(config.Provider).RequiresApiKey && string.IsNullOrWhiteSpace(config.ApiKey))
        {
            throw new InvalidOperationException("Enter the API key for this provider.");
        }
    }

    private static void EnsureSuccess(HttpResponseMessage response, string responseBody)
    {
        if (!response.IsSuccessStatusCode)
        {
            var detail = responseBody.Length > 800 ? responseBody[..800] : responseBody;
            throw new HttpRequestException($"AI request failed ({(int)response.StatusCode}): {detail}");
        }
    }

    private static string RequireText(string? text)
    {
        var result = text?.Trim() ?? "";
        return result.Length == 0
            ? throw new InvalidOperationException("The AI provider returned an empty response.")
            : result;
    }
}
