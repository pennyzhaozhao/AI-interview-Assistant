using System.IO;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace InterviewAssistant.Services;

public static class WindowsOcrService
{
    public static async Task<string> RecognizeAsync(string imagePath)
    {
        var bytes = await File.ReadAllBytesAsync(imagePath);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new InvalidOperationException("Windows OCR is unavailable. Install an OCR language in Windows Settings.");
        var result = await engine.RecognizeAsync(bitmap);
        return string.Join("\n", result.Lines.Select(line => line.Text)).Trim();
    }
}
